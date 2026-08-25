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

// GOP size (in frames) and keyframe interval (in seconds). Tuned for screen
// mirroring: frequent-enough keyframes for fast decoder (re)acquisition without
// blowing up the bitrate. noVNC needs an IDR whenever it creates a decoder
// context, so we also force one explicitly on demand.
static const int kH264GopSize = 30;
static const Float64 kH264KeyframeIntervalSeconds = 1.0;

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
    // Baseline profile + no reordering: no B-frames, decode-order == presentation-order.
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(kH264GopSize));

    if (@available(iOS 11.0, *)) {
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             (__bridge CFTypeRef)@(kH264KeyframeIntervalSeconds));
    }
    if (@available(iOS 12.0, *)) {
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowOpenGOP, kCFBooleanFalse);
    }

    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(30));

    // Emit BT.709 (sRGB) color space info in the SPS so browser decoders apply
    // the correct YUV->RGB conversion instead of guessing BT.601.
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);

    // Bitrate scaled to output size: ~2.5 Mbps at 720p-class, up to ~6 Mbps for large screens.
    int pixels = _width * _height;
    int bitRate = pixels >= 2'000'000 ? 6'000'000 : (pixels >= 1'000'000 ? 4'000'000 : 2'500'000);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(bitRate));

    // Streaming-friendly: cap instantaneous rate at ~1.5x the average.
    NSArray *limits = @[ @((int)(bitRate * 1.5)), @(1.0) ];
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_DataRateLimits, (__bridge CFArrayRef)limits);
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
