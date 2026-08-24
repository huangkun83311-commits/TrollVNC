#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TVH264EncoderOutputBlock)(NSData *naluData, BOOL isKeyFrame);

@interface TVH264Encoder : NSObject

@property (nonatomic, copy) TVH264EncoderOutputBlock outputBlock;
@property (nonatomic, readonly) int currentWidth;
@property (nonatomic, readonly) int currentHeight;

- (void)setFps:(int)fps;
- (void)setBitrate:(int)bitrate;
- (void)setKeyFrameInterval:(int)interval;
- (void)forceKeyFrame;
- (void)invalidate;

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
              orientation:(int)rotationQuad
                    scale:(CGFloat)scale;

@end

NS_ASSUME_NONNULL_END
