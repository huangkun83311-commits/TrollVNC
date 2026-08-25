#import "TVH264Encoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <rfb/rfb.h>

@interface TVH264Encoder ()
@property (nonatomic, assign) VTCompressionSessionRef session;
@property (nonatomic, assign) int fps;
@property (nonatomic, assign) int bitrate;
@property (nonatomic, assign) int keyFrameInterval;
@property (nonatomic, assign) int currentWidth;
@property (nonatomic, assign) int currentHeight;
@property (nonatomic, assign) int64_t frameCount;
@property (nonatomic, assign) BOOL needForceKeyFrame;
@property (nonatomic, strong) NSData *spsData;
@property (nonatomic, strong) NSData *ppsData;
@end

@implementation TVH264Encoder

- (instancetype)init {
    self = [super init];
    if (self) {
        _fps = 30;
        _bitrate = 2000 * 1024;
        _keyFrameInterval = 30;
        _session = NULL;
        _needForceKeyFrame = NO;
        _spsData = nil;
        _ppsData = nil;
        rfbLog("[ENC] init\n");
    }
    return self;
}

- (void)setFps:(int)fps {
    _fps = fps;
    if (_session) {
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(fps));
    }
}

- (void)setBitrate:(int)bitrate {
    _bitrate = bitrate;
    if (_session) {
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(bitrate));
    }
}

- (void)setKeyFrameInterval:(int)interval {
    _keyFrameInterval = interval;
    if (_session) {
        VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(interval));
    }
}

- (void)forceKeyFrame {
    rfbLog("[ENC] forceKeyFrame: _needForceKeyFrame %d -> YES\n", _needForceKeyFrame);
    _needForceKeyFrame = YES;
}

- (void)invalidate {
    rfbLog("[ENC] invalidate called, session=%p\n", _session);
    if (_session) {
        VTCompressionSessionCompleteFrames(_session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    _spsData = nil;
    _ppsData = nil;
}

- (void)dealloc {
    [self invalidate];
}

- (void)setupSessionIfNeeded:(int)width height:(int)height {
    if (_session && _currentWidth == width && _currentHeight == height) {
        return;
    }
    rfbLog("[ENC] setupSessionIfNeeded START: %dx%d, old session=%p\n", width, height, _session);
    [self invalidate];
    _currentWidth = width;
    _currentHeight = height;

    OSStatus status = VTCompressionSessionCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCMVideoCodecType_H264,
        NULL,
        NULL,
        NULL,
        &TVH264EncoderOutputCallback,
        (__bridge void *)self,
        &_session
    );
    rfbLog("[ENC] VTCompressionSessionCreate status=%d (0=ok), session=%p\n", (int)status, _session);
    if (status != noErr) {
        rfbLog("[ENC] FATAL: VTCompressionSessionCreate failed!\n");
        _session = NULL;
        return;
    }

    OSStatus s;
    s = VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    rfbLog("[ENC] set RealTime=true status=%d\n", (int)s);
    s = VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    rfbLog("[ENC] set AllowFrameReordering=false status=%d\n", (int)s);
    s = VTSessionSetProperty(_session, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(_fps));
    rfbLog("[ENC] set ExpectedFrameRate=%d status=%d\n", _fps, (int)s);
    s = VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(_bitrate));
    rfbLog("[ENC] set AverageBitRate=%d status=%d\n", _bitrate, (int)s);
    s = VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(_keyFrameInterval));
    rfbLog("[ENC] set MaxKeyFrameInterval=%d status=%d\n", _keyFrameInterval, (int)s);
    s = VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFTypeRef)@(1));
    rfbLog("[ENC] set MaxKeyFrameIntervalDuration=1 status=%d\n", (int)s);
    s = VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    rfbLog("[ENC] set Profile=Baseline status=%d\n", (int)s);

    status = VTCompressionSessionPrepareToEncodeFrames(_session);
    rfbLog("[ENC] PrepareToEncodeFrames status=%d\n", (int)status);
    if (status != noErr) {
        rfbLog("[ENC] FATAL: PrepareToEncodeFrames failed!\n");
        [self invalidate];
        return;
    }
    _frameCount = 0;
    _needForceKeyFrame = YES;
    rfbLog("[ENC] session READY, first frame will force keyframe\n");
}

static void TVH264EncoderOutputCallback(
    void *outputCallbackRefCon,
    void *sourceFrameRefCon,
    OSStatus status,
    VTEncodeInfoFlags infoFlags,
    CMSampleBufferRef sampleBuffer)
{
    TVH264Encoder *encoder = (__bridge TVH264Encoder *)outputCallbackRefCon;
    rfbLog("[ENC-CB] callback: status=%d, sampleBuffer=%p, infoFlags=0x%x\n",
           (int)status, sampleBuffer, (unsigned)infoFlags);

    if (status != noErr || !sampleBuffer) {
        rfbLog("[ENC-CB] skip: status!=noErr or sampleBuffer NULL\n");
        return;
    }

    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) {
        rfbLog("[ENC-CB] blockBuffer is NULL!\n");
        return;
    }
    size_t totalLength = CMBlockBufferGetDataLength(blockBuffer);
    rfbLog("[ENC-CB] blockBuffer totalLength=%zu\n", totalLength);
    if (totalLength < 5) {
        rfbLog("[ENC-CB] blockBuffer too short, skip\n");
        return;
    }

    // 直接读第一个 NALU type（AVCC：前4字节长度，第5字节是 NALU header）
    uint8_t naluHeader = 0;
    CMBlockBufferCopyDataBytes(blockBuffer, 4, 1, &naluHeader);
    int naluType = naluHeader & 0x1F;
    rfbLog("[ENC-CB] first NALU: header=0x%02X, type=%d (5=IDR,1=P,7=SPS,8=PPS)\n",
           naluHeader, naluType);

    // attachments 判断
    BOOL isKeyFrameAttach = YES;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    CFIndex attCount = attachments ? CFArrayGetCount(attachments) : 0;
    if (attachments && attCount > 0) {
        CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = (CFBooleanRef)CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync);
        rfbLog("[ENC-CB] attachments: count=%ld, notSync=%p\n", attCount, notSync);
        if (notSync && CFBooleanGetValue(notSync)) {
            isKeyFrameAttach = NO;
        }
    } else {
        rfbLog("[ENC-CB] attachments empty, isKeyFrame defaults YES\n");
    }

    // 用 NALU type 作为最终判断（更可靠）
    BOOL isKeyFrame = (naluType == 5);
    rfbLog("[ENC-CB] isKeyFrame: byAttach=%d, byNaluType=%d, using=%d\n",
           isKeyFrameAttach, isKeyFrame, isKeyFrame);

    // 关键帧：提取 SPS/PPS
    if (isKeyFrame) {
        CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        rfbLog("[ENC-CB] KEYFRAME! extracting SPS/PPS, formatDesc=%p\n", formatDesc);
        if (formatDesc) {
            size_t numParams = 0;
            const uint8_t *spsPtr = NULL;
            size_t spsLen = 0;
            const uint8_t *ppsPtr = NULL;
            size_t ppsLen = 0;
            OSStatus spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 0, &spsPtr, &spsLen, &numParams, NULL);
            OSStatus ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 1, &ppsPtr, &ppsLen, &numParams, NULL);
            rfbLog("[ENC-CB] SPS status=%d len=%zu, PPS status=%d len=%zu, numParams=%zu\n",
                   (int)spsStatus, spsLen, (int)ppsStatus, ppsLen, numParams);
            if (spsPtr && spsLen > 0) {
                encoder.spsData = [NSData dataWithBytes:spsPtr length:spsLen];
            }
            if (ppsPtr && ppsLen > 0) {
                encoder.ppsData = [NSData dataWithBytes:ppsPtr length:ppsLen];
            }
        } else {
            rfbLog("[ENC-CB] KEYFRAME but formatDesc NULL, cannot get SPS/PPS!\n");
        }
    }

    NSMutableData *naluData = [NSMutableData dataWithCapacity:totalLength];

    // 关键帧：先添加 SPS/PPS
    if (isKeyFrame) {
        const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
        if (encoder.spsData) {
            [naluData appendBytes:startCode length:4];
            [naluData appendData:encoder.spsData];
            rfbLog("[ENC-CB] appended SPS %lu bytes\n", (unsigned long)encoder.spsData.length);
        }
        if (encoder.ppsData) {
            [naluData appendBytes:startCode length:4];
            [naluData appendData:encoder.ppsData];
            rfbLog("[ENC-CB] appended PPS %lu bytes\n", (unsigned long)encoder.ppsData.length);
        }
    }

    // AVCC -> Annex-B 转换
    size_t offset = 0;
    int naluCount = 0;
    while (offset < totalLength) {
        size_t length = 0;
        char *dataPointer = NULL;
        CMBlockBufferGetDataPointer(blockBuffer, offset, &length, NULL, &dataPointer);
        if (length == 0 || dataPointer == NULL) {
            break;
        }
        size_t pos = 0;
        while (pos + 4 <= length) {
            uint32_t naluLength = 0;
            memcpy(&naluLength, dataPointer + pos, 4);
            naluLength = CFSwapInt32BigToHost(naluLength);
            pos += 4;
            if (pos + naluLength > length) {
                break;
            }
            const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
            [naluData appendBytes:startCode length:4];
            [naluData appendBytes:dataPointer + pos length:naluLength];
            naluCount++;
            pos += naluLength;
        }
        offset += length;
    }
    rfbLog("[ENC-CB] converted %d NALUs, final naluData length=%lu\n",
           naluCount, (unsigned long)naluData.length);

    if (naluData.length > 0 && encoder.outputBlock) {
        rfbLog("[ENC-CB] calling outputBlock: %lu bytes, isKeyFrame=%d\n",
               (unsigned long)naluData.length, isKeyFrame);
        encoder.outputBlock(naluData, isKeyFrame);
    } else {
        rfbLog("[ENC-CB] skip outputBlock: dataLen=%lu, outputBlock=%p\n",
               (unsigned long)naluData.length, encoder.outputBlock);
    }
}

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
              orientation:(int)rotationQuad
                    scale:(CGFloat)scale {
    int width = (int)CVPixelBufferGetWidth(pixelBuffer);
    int height = (int)CVPixelBufferGetHeight(pixelBuffer);
    if (rotationQuad == 1 || rotationQuad == 3) {
        int tmp = width;
        width = height;
        height = tmp;
    }
    width = (int)(width * scale);
    height = (int)(height * scale);

    [self setupSessionIfNeeded:width height:height];
    if (!_session) {
        rfbLog("[ENC] encodePixelBuffer: session NULL, skip!\n");
        return;
    }

    CMTime pts = CMTimeMake(_frameCount, _fps);
    _frameCount++;
    BOOL force = (_frameCount == 1 || _needForceKeyFrame);
    rfbLog("[ENC] encodePixelBuffer #%lld: force=%d (needForce=%d, count==1=%d)\n",
           _frameCount, force, _needForceKeyFrame, _frameCount == 1);

    OSStatus status;
    if (force) {
        CFTypeRef keys[1] = { kVTEncodeFrameOptionKey_ForceKeyFrame };
        CFTypeRef values[1] = { kCFBooleanTrue };
        CFDictionaryRef properties = CFDictionaryCreate(NULL, keys, values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        status = VTCompressionSessionEncodeFrame(_session, pixelBuffer, pts, kCMTimeInvalid, properties, NULL, NULL);
        rfbLog("[ENC] EncodeFrame WITH forceKeyFrame status=%d\n", (int)status);
        CFRelease(properties);
        _needForceKeyFrame = NO;
    } else {
        status = VTCompressionSessionEncodeFrame(_session, pixelBuffer, pts, kCMTimeInvalid, NULL, NULL, NULL);
        rfbLog("[ENC] EncodeFrame normal status=%d\n", (int)status);
    }
    if (status != noErr) {
        rfbLog("[ENC] FATAL: EncodeFrame failed status=%d\n", (int)status);
    }
}

@end
