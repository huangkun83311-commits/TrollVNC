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
    
    int _fps;
    int _bitrate;
    int _keyFrameInterval;
    int _profile;
    int _frameCount;
}

@end

@implementation TVH264Encoder

- (instancetype)init {
    self = [super init];
    if (self) {
        _encodeQueue = dispatch_queue_create("com.82flex.trollvnc.h264encoder", DISPATCH_QUEUE_SERIAL);
        _fps = 30;
        _bitrate = 3 * 1024 * 1024;
        _keyFrameInterval = 30;
        _profile = 0;
        _frameCount = 0;
        TVLog(@"✅ H264编码器初始化");
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
        _frameCount = 0;
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

- (int)getFps { return _fps; }
- (int)getBitrate { return _bitrate; }
- (int)getKeyFrameInterval { return _keyFrameInterval; }
- (int)getProfile { return _profile; }

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
        TVLog(@"❌ VTCompressionSessionCreate failed: %d", status);
        return;
    }

    int fps = _fps > 0 ? _fps : 30;
    int bitrate = _bitrate > 0 ? _bitrate : 3 * 1024 * 1024;
    int keyint = _keyFrameInterval > 0 ? _keyFrameInterval : fps * 2;

    CFStringRef profile = kVTProfileLevel_H264_Baseline_AutoLevel;
    switch (_profile) {
        case 0: profile = kVTProfileLevel_H264_Baseline_AutoLevel; break;
        case 1: profile = kVTProfileLevel_H264_Main_AutoLevel; break;
        case 2: profile = kVTProfileLevel_H264_High_AutoLevel; break;
        default: profile = kVTProfileLevel_H264_Baseline_AutoLevel; break;
    }

    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ProfileLevel, profile);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(keyint));
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFTypeRef)@(1));
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(fps));
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(bitrate));
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_DataRateLimits, (__bridge CFArrayRef)@[@(bitrate / 8), @1.0]);

    VTCompressionSessionPrepareToEncodeFrames(_compressionSession);

    _currentWidth = width;
    _currentHeight = height;
    _currentRotation = rotation;
    _currentScale = scale;
    _frameCount = 0;
    
    TVLog(@"✅ H264 encoder rebuilt: %dx%d, fps=%d, bitrate=%d, keyint=%d", width, height, fps, bitrate, keyint);
}

- (void)encodeFrameInternal:(CVPixelBufferRef)pixelBuffer {
    if (!_compressionSession) return;

    CMTime pts = CMTimeMake(CFAbsoluteTimeGetCurrent() * 1000, 1000);
    CMTime dur = CMTimeMake(1, _fps);
    VTEncodeInfoFlags flags = 0;
    
    if (_frameCount == 0 || _frameCount % _keyFrameInterval == 0) {
        CFDictionaryRef frameProps = NULL;
        const void *keys[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
        const void *values[] = {kCFBooleanTrue};
        frameProps = CFDictionaryCreate(NULL, keys, values, 1, NULL, NULL);
        
        VTCompressionSessionEncodeFrame(_compressionSession,
                                        pixelBuffer,
                                        pts,
                                        dur,
                                        frameProps, NULL, &flags);
        if (frameProps) CFRelease(frameProps);
        TVLog(@"🔑 关键帧 #%d", _frameCount);
    } else {
        VTCompressionSessionEncodeFrame(_compressionSession,
                                        pixelBuffer,
                                        pts,
                                        dur,
                                        NULL, NULL, &flags);
    }
    _frameCount++;
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
    _frameCount = 0;
}

#pragma mark - 回调（✅ 合并版 - 修复 SPS/PPS 分开发送问题）

static void tvH264CompressionOutputCallback(void *outputCallbackRefCon,
                                            void *sourceFrameRefCon,
                                            OSStatus status,
                                            VTEncodeInfoFlags infoFlags,
                                            CMSampleBufferRef sampleBuffer) {
    if (status != noErr) {
        TVLog(@"❌ 编码错误: %d", status);
        return;
    }
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        TVLog(@"⚠️ sampleBuffer 未就绪");
        return;
    }

    TVH264Encoder *encoder = (__bridge TVH264Encoder *)outputCallbackRefCon;
    if (!encoder.outputBlock) {
        TVLog(@"🔴 outputBlock 为 nil！");
        return;
    }

    // 判断是否关键帧
    BOOL keyFrame = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = (CFBooleanRef)CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync);
        keyFrame = !notSync || !CFBooleanGetValue(notSync);
    }
    
    // ✅ 合并所有 NAL 单元为一个数据包
    NSMutableData *combinedData = [NSMutableData data];
    const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
    int nalCount = 0;
    
    // 1. 如果是关键帧，提取 SPS/PPS
    if (keyFrame) {
        CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (formatDesc) {
            const uint8_t *spsPtr = NULL;
            size_t spsLen = 0;
            const uint8_t *ppsPtr = NULL;
            size_t ppsLen = 0;
            
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 0, &spsPtr, &spsLen, NULL, NULL);
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 1, &ppsPtr, &ppsLen, NULL, NULL);
            
            if (spsPtr && spsLen > 0) {
                [combinedData appendBytes:startCode length:4];
                [combinedData appendBytes:spsPtr length:spsLen];
                nalCount++;
                TVLog(@"  ✅ 添加 SPS: %zu 字节", spsLen);
            }
            if (ppsPtr && ppsLen > 0) {
                [combinedData appendBytes:startCode length:4];
                [combinedData appendBytes:ppsPtr length:ppsLen];
                nalCount++;
                TVLog(@"  ✅ 添加 PPS: %zu 字节", ppsLen);
            }
        }
    }

    // 2. 提取 NAL 数据（SEI、IDR、P/B帧等）
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!dataBuffer) {
        TVLog(@"⚠️ dataBuffer 为 nil");
        return;
    }
    
    size_t totalLength = CMBlockBufferGetDataLength(dataBuffer);
    if (totalLength == 0) {
        TVLog(@"⚠️ 数据长度为 0");
        return;
    }
    
    uint8_t *dataPointer = malloc(totalLength);
    if (!dataPointer) {
        TVLog(@"❌ 内存分配失败");
        return;
    }
    
    OSStatus blockStatus = CMBlockBufferCopyDataBytes(dataBuffer, 0, totalLength, dataPointer);
    if (blockStatus != noErr) {
        free(dataPointer);
        TVLog(@"❌ 数据复制失败");
        return;
    }

    static const int AVCCHeaderLength = 4;
    size_t bufferOffset = 0;

    while (bufferOffset + AVCCHeaderLength <= totalLength) {
        uint32_t NALUnitLength = 0;
        memcpy(&NALUnitLength, dataPointer + bufferOffset, AVCCHeaderLength);
        NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);
        
        if (NALUnitLength == 0 || bufferOffset + AVCCHeaderLength + NALUnitLength > totalLength) {
            break;
        }

        [combinedData appendBytes:startCode length:4];
        [combinedData appendBytes:(dataPointer + bufferOffset + AVCCHeaderLength)
                           length:NALUnitLength];
        nalCount++;

        bufferOffset += AVCCHeaderLength + NALUnitLength;
    }
    
    free(dataPointer);

    // ✅ 一次性发送所有数据
    if (combinedData.length > 0) {
        TVLog(@"📤 发送 H264: %lu 字节, NAL数=%d, keyFrame=%@", 
              (unsigned long)combinedData.length, nalCount, keyFrame ? @"YES" : @"NO");
        encoder.outputBlock(combinedData, keyFrame);
    }
}

@end
