#import "TVH264Encoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <Accelerate/Accelerate.h>

#ifndef TVLog
#define TVLog(fmt, ...) NSLog(@"[H264] " fmt, ##__VA_ARGS__)
#endif

@interface TVH264Encoder () {
    VTCompressionSessionRef _compressionSession;
    dispatch_queue_t _encodeQueue;
    int _currentWidth;
    int _currentHeight;
    int _currentRotation;
    CGFloat _currentScale;
    CVPixelBufferRef _rotatedPixelBuffer;
    CVPixelBufferRef _scaledPixelBuffer;
    void *_rotateScratch;
    size_t _rotateScratchSize;
    
    // H264 动态参数
    int _fps;
    int _bitrate;
    int _keyFrameInterval;
    int _profile;
}

@end

@implementation TVH264Encoder

- (instancetype)init {
    self = [super init];
    if (self) {
        _encodeQueue = dispatch_queue_create("com.82flex.trollvnc.h264encoder", DISPATCH_QUEUE_SERIAL);
        
        // 默认参数
        _fps = 30;
        _bitrate = 3 * 1024 * 1024;  // 3Mbps
        _keyFrameInterval = 60;
        _profile = 2;  // High
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
    if (_rotateScratch) {
        free(_rotateScratch);
        _rotateScratch = NULL;
    }
}

#pragma mark - 参数设置

- (void)setFps:(int)fps {
    if (fps != _fps && fps > 0 && fps <= 120) {
        _fps = fps;
        [self rebuildSessionIfNeeded];
        TVLog(@"H264: FPS set to %d", _fps);
    }
}

- (void)setBitrate:(int)bitrate {
    if (bitrate != _bitrate && bitrate > 0) {
        _bitrate = bitrate;
        [self rebuildSessionIfNeeded];
        TVLog(@"H264: Bitrate set to %d bps", _bitrate);
    }
}

- (void)setKeyFrameInterval:(int)interval {
    if (interval != _keyFrameInterval && interval > 0) {
        _keyFrameInterval = interval;
        [self rebuildSessionIfNeeded];
        TVLog(@"H264: KeyFrameInterval set to %d", _keyFrameInterval);
    }
}

- (void)setProfile:(int)profile {
    if (profile != _profile && profile >= 0 && profile <= 2) {
        _profile = profile;
        [self rebuildSessionIfNeeded];
        TVLog(@"H264: Profile set to %d", _profile);
    }
}

- (int)getFps {
    return _fps;
}

- (int)getBitrate {
    return _bitrate;
}

- (int)getKeyFrameInterval {
    return _keyFrameInterval;
}

- (int)getProfile {
    return _profile;
}

#pragma mark - 编码核心

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
              orientation:(int)rotationQuad
                    scale:(CGFloat)scale {

    if (!pixelBuffer) return;

    int srcW = (int)CVPixelBufferGetWidth(pixelBuffer);
    int srcH = (int)CVPixelBufferGetHeight(pixelBuffer);

    int rotW = (rotationQuad % 2 == 0) ? srcW : srcH;
    int rotH = (rotationQuad % 2 == 0) ? srcH : srcW;

    int outW = MAX(1, (int)(rotW * scale));
    int outH = MAX(1, (int)(rotH * scale));
    outW = (outW + 3) & ~3;

    CVPixelBufferRef finalBuffer = NULL;

    if (rotationQuad != 0 || (srcW != outW || srcH != outH)) {
        finalBuffer = [self convertPixelBuffer:pixelBuffer
                                   rotationQuad:rotationQuad
                                        outWidth:outW
                                       outHeight:outH];
    } else {
        finalBuffer = CVPixelBufferRetain(pixelBuffer);
    }

    if (!finalBuffer) return;

    dispatch_async(_encodeQueue, ^{
        [self rebuildSessionIfNeededWithWidth:outW
                                       height:outH
                                       rotation:rotationQuad
                                         scale:scale];

        [self encodeFrameInternal:finalBuffer];
        CVPixelBufferRelease(finalBuffer);
    });
}

- (CVPixelBufferRef)convertPixelBuffer:(CVPixelBufferRef)src
                          rotationQuad:(int)rotationQuad
                               outWidth:(int)outW
                              outHeight:(int)outH {

    int srcW = (int)CVPixelBufferGetWidth(src);
    int srcH = (int)CVPixelBufferGetHeight(src);

    int rotW = (rotationQuad % 2 == 0) ? srcW : srcH;
    int rotH = (rotationQuad % 2 == 0) ? srcH : srcW;

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);

    void *srcBase = CVPixelBufferGetBaseAddress(src);
    size_t srcBPR = CVPixelBufferGetBytesPerRow(src);

    vImage_Buffer srcBuf = {
        .data = srcBase,
        .width = (vImagePixelCount)srcW,
        .height = (vImagePixelCount)srcH,
        .rowBytes = srcBPR
    };

    vImage_Buffer rotBuf = {0};
    vImage_Buffer tmpRot = {0};

    if (rotationQuad != 0) {
        if (!_rotateScratch || _rotateScratchSize < rotW * rotH * 4) {
            _rotateScratchSize = rotW * rotH * 4;
            _rotateScratch = realloc(_rotateScratch, _rotateScratchSize);
            memset(_rotateScratch, 0, _rotateScratchSize);
        }

        rotBuf.data = _rotateScratch;
        rotBuf.width = (vImagePixelCount)rotW;
        rotBuf.height = (vImagePixelCount)rotH;
        rotBuf.rowBytes = rotW * 4;

        uint8_t rotation = kRotate0DegreesClockwise;
        switch (rotationQuad & 3) {
            case 1: rotation = kRotate90DegreesClockwise; break;
            case 2: rotation = kRotate180DegreesClockwise; break;
            case 3: rotation = kRotate270DegreesClockwise; break;
        }

        uint8_t bg[4] = {0, 0, 0, 0};
        vImage_Error err = vImageRotate90_ARGB8888(&srcBuf, &rotBuf, rotation, bg, kvImageNoFlags);
        if (err != kvImageNoError) {
            CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
            return NULL;
        }

        tmpRot = rotBuf;
    } else {
        tmpRot = srcBuf;
    }

    CVPixelBufferRef outBuffer = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferWidthKey: @(outW),
        (id)kCVPixelBufferHeightKey: @(outH),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    CVPixelBufferCreate(kCFAllocatorDefault, outW, outH, kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs, &outBuffer);
    if (!outBuffer) {
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(outBuffer, 0);
    void *outBase = CVPixelBufferGetBaseAddress(outBuffer);
    size_t outBPR = CVPixelBufferGetBytesPerRow(outBuffer);

    vImage_Buffer dstBuf = {
        .data = outBase,
        .width = (vImagePixelCount)outW,
        .height = (vImagePixelCount)outH,
        .rowBytes = outBPR
    };

    if (tmpRot.width == dstBuf.width && tmpRot.height == dstBuf.height) {
        for (int y = 0; y < outH; y++) {
            memcpy((uint8_t *)outBase + y * outBPR,
                   (uint8_t *)tmpRot.data + y * tmpRot.rowBytes,
                   outW * 4);
        }
    } else {
        void *temp = malloc(vImageScale_ARGB8888(&tmpRot, &dstBuf, NULL, kvImageGetTempBufferSize));
        if (temp) {
            vImage_Error err = vImageScale_ARGB8888(&tmpRot, &dstBuf, temp, kvImageHighQualityResampling);
            if (err != kvImageNoError) {
                NSLog(@"vImageScale failed: %ld", (long)err);
            }
            free(temp);
        }
    }

    CVPixelBufferUnlockBaseAddress(outBuffer, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);

    return outBuffer;
}

#pragma mark - 编码器管理

- (void)rebuildSessionIfNeeded {
    if (_compressionSession) {
        [self rebuildSessionIfNeededWithWidth:_currentWidth
                                       height:_currentHeight
                                     rotation:_currentRotation
                                        scale:_currentScale];
    }
}

- (void)rebuildSessionIfNeededWithWidth:(int)width
                                 height:(int)height
                               rotation:(int)rotation
                                  scale:(CGFloat)scale {
    if (_compressionSession &&
        _currentWidth == width &&
        _currentHeight == height &&
        _currentRotation == rotation &&
        _currentScale == scale) {
        return;
    }

    [self invalidate];

    OSStatus status = VTCompressionSessionCreate(NULL, width, height, kCMVideoCodecType_H264,
                                                  NULL, NULL, NULL,
                                                  tvH264CompressionOutputCallback,
                                                  (__bridge void *)self,
                                                  &_compressionSession);
    if (status != noErr) {
        TVLog(@"VTCompressionSessionCreate failed: %d", status);
        return;
    }

    // 使用动态参数
    int fps = _fps > 0 ? _fps : 30;
    int bitrate = _bitrate > 0 ? _bitrate : 3 * 1024 * 1024;
    int keyint = _keyFrameInterval > 0 ? _keyFrameInterval : fps * 2;

    // 选择 Profile
    CFStringRef profile = kVTProfileLevel_H264_High_AutoLevel;
    switch (_profile) {
        case 0: profile = kVTProfileLevel_H264_Baseline_AutoLevel; break;
        case 1: profile = kVTProfileLevel_H264_Main_AutoLevel; break;
        case 2: profile = kVTProfileLevel_H264_High_AutoLevel; break;
        default: profile = kVTProfileLevel_H264_High_AutoLevel; break;
    }

    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ProfileLevel, profile);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(keyint));
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(fps));
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(bitrate));
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_DataRateLimits, (__bridge CFArrayRef)@[@(bitrate / 8), @1.0]);

    VTCompressionSessionPrepareToEncodeFrames(_compressionSession);

    _currentWidth = width;
    _currentHeight = height;
    _currentRotation = rotation;
    _currentScale = scale;
    
    TVLog(@"H264 encoder rebuilt: %dx%d, fps=%d, bitrate=%d, keyint=%d, profile=%d",
          width, height, fps, bitrate, keyint, _profile);
}

- (void)encodeFrameInternal:(CVPixelBufferRef)pixelBuffer {
    if (!_compressionSession) return;

    CMTime pts = CMTimeMake(CFAbsoluteTimeGetCurrent() * 1000, 1000);
    CMTime dur = CMTimeMake(1, 30);

    VTEncodeInfoFlags flags = 0;
    VTCompressionSessionEncodeFrame(_compressionSession,
                                    pixelBuffer,
                                    pts,
                                    dur,
                                    NULL, NULL, &flags);
}

- (void)invalidate {
    if (_compressionSession) {
        VTCompressionSessionCompleteFrames(_compressionSession, kCMTimeInvalid);
        VTCompressionSessionInvalidate(_compressionSession);
        CFRelease(_compressionSession);
        _compressionSession = NULL;
    }

    _currentWidth = 0;
    _currentHeight = 0;
    _currentRotation = -1;
    _currentScale = 0;
}

#pragma mark - 回调

static void tvH264CompressionOutputCallback(void *outputCallbackRefCon,
                                            void *sourceFrameRefCon,
                                            OSStatus status,
                                            VTEncodeInfoFlags infoFlags,
                                            CMSampleBufferRef sampleBuffer) {
    if (status != noErr) return;
    if (!CMSampleBufferDataIsReady(sampleBuffer)) return;

    TVH264Encoder *encoder = (__bridge TVH264Encoder *)outputCallbackRefCon;
    if (!encoder.outputBlock) return;

    bool keyFrame = !CFDictionaryContainsKey(
        (CFDictionaryRef)CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true), 0),
        (const void *)kCMSampleAttachmentKey_NotSync);

    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length = 0;
    size_t totalLength = 0;
    char *dataPointer = NULL;

    OSStatus blockStatus = CMBlockBufferGetDataPointer(dataBuffer, 0, &length, &totalLength, &dataPointer);
    if (blockStatus != noErr) return;

    static const int AVCCHeaderLength = 4;
    size_t bufferOffset = 0;

    while (bufferOffset < totalLength - AVCCHeaderLength) {
        uint32_t NALUnitLength = 0;
        memcpy(&NALUnitLength, dataPointer + bufferOffset, AVCCHeaderLength);
        NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);

        NSData *naluData = [[NSData alloc] initWithBytes:(dataPointer + bufferOffset + AVCCHeaderLength)
                                                  length:NALUnitLength];
        
        TVH264EncoderOutputBlock block = encoder.outputBlock;
        if (block) {
            block(naluData, keyFrame);
        }

        bufferOffset += AVCCHeaderLength + NALUnitLength;
    }
}

@end
