/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import "H264Encoder.h"

#import <VideoToolbox/VideoToolbox.h>

#import <atomic>

#import "Logging.h"

// GOP: emit an IDR every N frames so a client can (re)join the stream. A
// smaller value makes rejoin faster but sends a large IDR more often, which
// causes a visible stutter every N frames; keep it large to stay smooth.
static const int kH264GopSize = 120;

// 4-byte Annex-B start code emitted before every NAL unit.
static const uint8_t kAnnexBStartCode[4] = {0x00, 0x00, 0x00, 0x01};

@interface TVH264Encoder ()
- (void)handleEncodedSampleBuffer:(CMSampleBufferRef)sampleBuffer status:(OSStatus)status;
@end

static void tv_h264_output_callback(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status,
                                    VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {
    (void)sourceFrameRefCon;
    (void)infoFlags;

    TVH264Encoder *encoder = (__bridge TVH264Encoder *)outputCallbackRefCon;
    [encoder handleEncodedSampleBuffer:sampleBuffer status:status];
}

@implementation TVH264Encoder {
    VTCompressionSessionRef _session;
    dispatch_queue_t _queue; // serialises encode calls into the VT session
    dispatch_queue_t _deliverQueue; // serialises outputHandler invocations
    int _width;
    int _height;
    int64_t _frameIndex;
    std::atomic<bool> _pendingKeyframeRequest;
    std::atomic<bool> _invalidated;
}

- (int)width { return _width; }
- (int)height { return _height; }

- (instancetype)initWithWidth:(int)width height:(int)height {
    self = [super init];
    if (!self)
        return nil;

    _width = width;
    _height = height;
    _frameIndex = 0;
    _pendingKeyframeRequest.store(true); // first frame must be an IDR
    _invalidated.store(false);

    _queue = dispatch_queue_create("com.82flex.trollvnc.h264.encode", DISPATCH_QUEUE_SERIAL);
    _deliverQueue = dispatch_queue_create("com.82flex.trollvnc.h264.deliver", DISPATCH_QUEUE_SERIAL);

    OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault,
                                                 (int32_t)width,
                                                 (int32_t)height,
                                                 kCMVideoCodecType_H264,
                                                 NULL, // let the system pick HW/SW encoder
                                                 NULL, // accept BGRA pixel buffers we provide
                                                 kCFAllocatorDefault,
                                                 tv_h264_output_callback,
                                                 (__bridge void *)self,
                                                 &_session);
    if (status != noErr || !_session) {
        TVLog(@"H264: VTCompressionSessionCreate failed: %d", (int)status);
        return nil;
    }

    [self configureSession];
    return self;
}

- (void)configureSession {
    // iOS hardware H.264 encoders natively support Main/High. Use Constrained
    // High where available (iOS 15+), else High (iOS 14). Keep the property set
    // minimal: extra props such as RealTime/AllowFrameReordering/DataRateLimits
    // can change the emitted SPS in ways some browser WebCodecs decoders reject
    // (black screen with no error).
    // Real-time: emit each frame immediately instead of buffering (required for
    // our continuous push-style pipeline; the demand-gated reference encoder
    // doesn't need it).
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);

    if (@available(iOS 15.0, *)) {
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel);
    } else {
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
    }

    // Cap quantization to avoid over-compressing screen content (matches the
    // known-good reference encoder).
    if (@available(iOS 15.0, *)) {
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxAllowedFrameQP, (__bridge CFTypeRef)@(48));
    }

    // Periodic IDR so a client can (re)join at a keyframe.
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(kH264GopSize));

    // No B-frames: decode order == presentation order. noVNC's H264 decoder
    // matches decoder output to its pending-frame queue by timestamp and throws
    // on reordered (B-frame) output, which stalls rendering after the first
    // frame.
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);

    // NOTE: no explicit ColorPrimaries/TransferFunction/YCbCrMatrix (BT.709)
    // SPS VUI. The iOS hardware encoder's bare SPS is the most compatible
    // across browsers; extra VUI fields were a suspected cause of the Windows
    // Chrome black-screen (decodes fine on macOS but not on Windows).

    // Bitrate scaled to output size: ~4 Mbps for small screens, 6 Mbps for large.
    int pixels = _width * _height;
    int bitRate = pixels >= 2'000'000 ? 3'000'000 : 2'000'000;
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(bitRate));
}

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer forceKeyframe:(BOOL)forceKeyframe {
    if (!_session || !pixelBuffer || _invalidated.load())
        return;

    if (forceKeyframe)
        _pendingKeyframeRequest.store(true);

    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(_queue, ^{
        if (!self->_session || self->_invalidated.load()) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }

        BOOL wantKeyframe = self->_pendingKeyframeRequest.exchange(false);

        int64_t frameIndex = self->_frameIndex++;
        CMTime pts = CMTimeMake(frameIndex, 30);
        CMTime duration = CMTimeMake(1, 30);

        CFDictionaryRef frameProperties = NULL;
        if (wantKeyframe) {
            const void *keys[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
            const void *values[] = {kCFBooleanTrue};
            frameProperties = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                                                 &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
        }

        VTEncodeInfoFlags infoFlags = 0;
        OSStatus status = VTCompressionSessionEncodeFrame(self->_session,
                                                          pixelBuffer,
                                                          pts,
                                                          duration,
                                                          frameProperties,
                                                          NULL,
                                                          &infoFlags);
        if (frameProperties)
            CFRelease(frameProperties);
        CVPixelBufferRelease(pixelBuffer);

        if (status != noErr) {
            TVLog(@"H264: VTCompressionSessionEncodeFrame failed: %d", (int)status);
        }
    });
}

- (void)requestKeyframe {
    if (_invalidated.load())
        return;
    _pendingKeyframeRequest.store(true);
}

#pragma mark - Output

- (void)handleEncodedSampleBuffer:(CMSampleBufferRef)sampleBuffer status:(OSStatus)status {
    if (status != noErr || !sampleBuffer) {
        TVLog(@"H264: encode callback status %d", (int)status);
        return;
    }
    if (_invalidated.load())
        return;

    // Determine whether this access unit is a sync (IDR) frame.
    BOOL isKeyframe = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef dependsOnOthers = (CFBooleanRef)CFDictionaryGetValue(dict, kCMSampleAttachmentKey_DependsOnOthers);
        if (dependsOnOthers != NULL)
            isKeyframe = (dependsOnOthers == kCFBooleanFalse);
    }

    NSData *annexB = [self annexBDataForSampleBuffer:sampleBuffer includeParameterSets:isKeyframe];
    if (!annexB || annexB.length == 0) {
        TVLog(@"H264: empty access unit (keyframe=%d)", isKeyframe);
        return;
    }

    void (^handler)(NSData *, BOOL) = self.outputHandler;
    if (!handler) {
        TVLog(@"H264: no output handler installed");
        return;
    }

    dispatch_async(_deliverQueue, ^{
        handler(annexB, isKeyframe);
    });
}

// Convert one CMSampleBuffer (length-prefixed NAL units) into an Annex-B stream.
// For IDR frames the SPS/PPS from the format description are prepended so the
// access unit is self-describing for a fresh decoder.
- (NSData *)annexBDataForSampleBuffer:(CMSampleBufferRef)sampleBuffer includeParameterSets:(BOOL)includeParameterSets {
    NSMutableData *out = [NSMutableData data];

    if (includeParameterSets) {
        CMVideoFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (formatDesc) {
            size_t spsCount = 0, ppsCount = 0;
            const uint8_t *sps = NULL;
            const uint8_t *pps = NULL;
            size_t spsLen = 0, ppsLen = 0;

            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 0, &sps, &spsLen, &spsCount, NULL);
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 1, &pps, &ppsLen, &ppsCount, NULL);

            if (sps && spsLen) {
                [out appendBytes:kAnnexBStartCode length:sizeof(kAnnexBStartCode)];
                [out appendBytes:sps length:spsLen];
            }
            if (pps && ppsLen) {
                [out appendBytes:kAnnexBStartCode length:sizeof(kAnnexBStartCode)];
                [out appendBytes:pps length:ppsLen];
            }
        }
    }

    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer)
        return out;

    char *data = NULL;
    size_t totalLength = 0;
    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &data);
    if (status != kCMBlockBufferNoErr || !data || totalLength == 0)
        return out;

    // NAL units are length-prefixed with a 4-byte big-endian length.
    size_t offset = 0;
    while (offset + 4 <= totalLength) {
        uint32_t nalLength = ((uint8_t)data[offset] << 24) | ((uint8_t)data[offset + 1] << 16) |
                             ((uint8_t)data[offset + 2] << 8) | ((uint8_t)data[offset + 3]);
        offset += 4;
        if (nalLength == 0 || offset + nalLength > totalLength)
            break;

        // Skip SEI (type 6) NAL units. VideoToolbox emits a "user data
        // unregistered" SEI with its encoder info that some browser WebCodecs
        // decoders (notably Windows Chromium) choke on; it is optional metadata
        // and safe to drop.
        uint8_t nalType = ((uint8_t)data[offset]) & 0x1f;
        if (nalType == 6) {
            offset += nalLength;
            continue;
        }

        [out appendBytes:kAnnexBStartCode length:sizeof(kAnnexBStartCode)];
        [out appendBytes:(data + offset) length:nalLength];
        offset += nalLength;
    }

    return out;
}

- (void)invalidate {
    if (_invalidated.exchange(true))
        return;

    dispatch_sync(_queue, ^{
        if (self->_session) {
            VTCompressionSessionInvalidate(self->_session);
            CFRelease(self->_session);
            self->_session = NULL;
        }
    });
}

- (void)dealloc {
    if (_session) {
        VTCompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
}

@end
