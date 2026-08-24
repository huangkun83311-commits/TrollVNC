#import "TVH264Encoder.h"
#import <VideoToolbox/VideoToolbox.h>

@interface TVH264Encoder ()
@property (nonatomic, assign) VTCompressionSessionRef session;
@property (nonatomic, assign) int fps;
@property (nonatomic, assign) int bitrate;
@property (nonatomic, assign) int keyFrameInterval;
@property (nonatomic, assign) int currentWidth;
@property (nonatomic, assign) int currentHeight;
@property (nonatomic, assign) int64_t frameCount;
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
        _spsData = nil;
        _ppsData = nil;
    }
    return self;
}

- (void)invalidate {
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

    if (status != noErr) {
        NSLog(@"TVH264Encoder: VTCompressionSessionCreate failed: %d", (int)status);
        _session = NULL;
        return;
    }

    VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(_fps));
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(_bitrate));
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(_keyFrameInterval));
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFTypeRef)@(1));
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);

    status = VTCompressionSessionPrepareToEncodeFrames(_session);
    if (status != noErr) {
        NSLog(@"TVH264Encoder: PrepareToEncodeFrames failed: %d", (int)status);
        [self invalidate];
        return;
    }

    _frameCount = 0;
}

static void TVH264EncoderOutputCallback(
    void *outputCallbackRefCon,
    void *sourceFrameRefCon,
    OSStatus status,
    VTEncodeInfoFlags infoFlags,
    CMSampleBufferRef sampleBuffer)
{
    TVH264Encoder *encoder = (__bridge TVH264Encoder *)outputCallbackRefCon;
    if (status != noErr || !sampleBuffer) {
        return;
    }

    BOOL isKeyFrame = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = (CFBooleanRef)CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync);
        isKeyFrame = !CFBooleanGetValue(notSync);
    }

    // 关键帧：提取 SPS/PPS
    if (isKeyFrame) {
        CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (formatDesc) {
            size_t numParams = 0;
            const uint8_t *spsPtr = NULL;
            size_t spsLen = 0;
            const uint8_t *ppsPtr = NULL;
            size_t ppsLen = 0;

            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 0, &spsPtr, &spsLen, &numParams, NULL);
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 1, &ppsPtr, &ppsLen, &numParams, NULL);

            if (spsPtr && spsLen > 0) {
                encoder.spsData = [NSData dataWithBytes:spsPtr length:spsLen];
            }
            if (ppsPtr && ppsLen > 0) {
                encoder.ppsData = [NSData dataWithBytes:ppsPtr length:ppsLen];
            }
        }
    }

    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) {
        return;
    }

    size_t totalLength = CMBlockBufferGetDataLength(blockBuffer);
    NSMutableData *naluData = [NSMutableData dataWithCapacity:totalLength];

    // 关键帧：先添加 SPS/PPS
    if (isKeyFrame) {
        const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
        if (encoder.spsData) {
            [naluData appendBytes:startCode length:4];
            [naluData appendData:encoder.spsData];
        }
        if (encoder.ppsData) {
            [naluData appendBytes:startCode length:4];
            [naluData appendData:encoder.ppsData];
        }
    }

    size_t offset = 0;
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
            pos += naluLength;
        }

        offset += length;
    }

    if (naluData.length > 0 && encoder.outputBlock) {
        encoder.outputBlock(naluData, isKeyFrame);
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
        return;
    }

    CMTime pts = CMTimeMake(_frameCount, _fps);
    _frameCount++;

    // 第一帧强制关键帧
    if (_frameCount == 1) {
        VTCompressionSessionEncodeFrame(
            _session,
            pixelBuffer,
            pts,
            kCMTimeInvalid,
            (CFDictionaryRef)@{
                (__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES
            },
            NULL,
            NULL
        );
    } else {
        VTCompressionSessionEncodeFrame(_session, pixelBuffer, pts, kCMTimeInvalid, NULL, NULL, NULL);
    }
}

@end
