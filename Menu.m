@import UIKit;
@import Foundation;
@import CoreGraphics;
@import QuartzCore;
@import AVFoundation;

@interface DiscordMenu : NSObject
@property (nonatomic, strong) UIView *box;
+ (instancetype)shared;
- (void)setup;
- (void)checkMic;
- (void)drag:(UIPanGestureRecognizer *)pan;
@end

@implementation DiscordMenu

+ (instancetype)shared {
    static DiscordMenu *instance = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        instance = [[DiscordMenu alloc] init];
    });
    return instance;
}

- (void)setup {
    UIWindow *win = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.isKeyWindow) {
                    win = w;
                    break;
                }
            }
        }
    }
    if (!win) {
        win = [UIApplication sharedApplication].windows.firstObject;
    }
    if (!win) return;

    self.box = [[UIView alloc] initWithFrame:CGRectMake(60, 180, 140, 140)];
    self.box.backgroundColor = [UIColor colorWithRed:0.12 green:0.13 blue:0.15 alpha:0.95];
    self.box.layer.cornerRadius = 22.0;
    self.box.layer.masksToBounds = YES;
    self.box.layer.borderWidth = 2.0;
    self.box.layer.borderColor = [UIColor colorWithRed:0.35 green:0.40 blue:0.95 alpha:1.0].CGColor;
    self.box.layer.zPosition = 9999;
    self.box.hidden = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 12, 140, 20)];
    title.text = @"MIC MENU";
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:14];
    [self.box addSubview:title];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    [self.box addGestureRecognizer:pan];

    [win addSubview:self.box];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(checkMic) name:AVAudioSessionRouteChangeNotification object:nil];
    [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(checkMic) userInfo:nil repeats:YES];
}

- (void)checkMic {
    dispatch_async(dispatch_get_main_queue(), ^{
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSString *cat = [session category];
        BOOL isRecordCategory = [cat isEqualToString:AVAudioSessionCategoryPlayAndRecord] || [cat isEqualToString:AVAudioSessionCategoryRecord];
        BOOL hasMicInput = session.currentRoute.inputs.count > 0;
        BOOL usingMic = isRecordCategory && hasMicInput;
        self.box.hidden = !usingMic;
        if (usingMic) {
            [self.box.superview bringSubviewToFront:self.box];
        }
    });
}

- (void)drag:(UIPanGestureRecognizer *)pan {
    CGPoint trans = [pan translationInView:self.box.superview];
    pan.view.center = CGPointMake(pan.view.center.x + trans.x, pan.view.center.y + trans.y);
    [pan setTranslation:CGPointZero inView:self.box.superview];
}

@end

__attribute__((constructor))
static void startMenu() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[DiscordMenu shared] setup];
    });
}
