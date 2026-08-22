#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TVH264EncoderOutputBlock)(NSData *naluData, BOOL isKeyFrame);

@interface TVH264Encoder : NSObject

@property (nonatomic, copy, nullable) TVH264EncoderOutputBlock outputBlock;

// H264 参数动态设置方法
- (void)setFps:(int)fps;
- (void)setBitrate:(int)bitrate;        // bps
- (void)setKeyFrameInterval:(int)interval;
- (void)setProfile:(int)profile;        // 0=Baseline, 1=Main, 2=High

// 获取当前参数
- (int)getFps;
- (int)getBitrate;
- (int)getKeyFrameInterval;
- (int)getProfile;

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
              orientation:(int)rotationQuad
                    scale:(CGFloat)scale;

- (void)invalidate;

// ✅ 强制下一帧为关键帧
- (void)forceKeyFrame;

@end

NS_ASSUME_NONNULL_END
