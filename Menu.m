@import UIKit;
@import Foundation;
@import CoreGraphics;
@import QuartzCore;
@import AVFoundation;
@import AudioToolbox;

static BOOL gEchoEnabled = NO;
static float gParamEcho = 0.85f;
static float gParamGain = 0.50f;
static BOOL gLongNganEnabled = YES;
static float gParamBass = 0.60f;

static float gEchoBuffer[48000];
static int gEchoWritePos = 0;
static float gLowPassState = 0.0f;

static BOOL gIsRecordingTest = NO;
static int16_t gTestRecordBuffer[480000];
static int gTestRecordCount = 0;

static float applyWarSingleSample(float x, float *echoBuf, int *writePos, float *lpState) {
    float echoMix = gParamEcho * 3.5f;
    float warGain = 1.0f + (gParamGain * 19.0f);
    float bassBoost = gParamBass * 12.0f;
    float feedback = gLongNganEnabled ? 0.84f : 0.32f;
    int delay1 = gLongNganEnabled ? 10500 : 5000;
    int delay2 = gLongNganEnabled ? 19000 : 8500;
    int delay3 = gLongNganEnabled ? 31000 : 12000;

    *lpState = *lpState + 0.11f * (x - *lpState);
    float voice = x + ((*lpState) * bassBoost);

    int wp = *writePos;
    int r1 = (wp + 48000 - delay1) % 48000;
    int r2 = (wp + 48000 - delay2) % 48000;
    int r3 = (wp + 48000 - delay3) % 48000;
    float delayed = echoBuf[r1] * 0.68f + echoBuf[r2] * 0.48f + echoBuf[r3] * 0.34f;

    float fb = voice + delayed * feedback;
    if (fb > 1.0f) fb = 1.0f;
    if (fb < -1.0f) fb = -1.0f;
    echoBuf[wp] = fb;
    *writePos = (wp + 1) % 48000;

    float out = (voice + delayed * echoMix) * warGain;
    if (out > 0.99f) out = 0.99f;
    if (out < -0.99f) out = -0.99f;
    return out;
}

static void processMicEcho(AudioBufferList *ioData, UInt32 inNumberFrames) {
    if (!ioData || ioData->mNumberBuffers == 0 || inNumberFrames == 0) return;

    AudioBuffer *buf = &ioData->mBuffers[0];
    if (!buf->mData || buf->mDataByteSize == 0) return;

    UInt32 bytesPerFrame = buf->mDataByteSize / inNumberFrames;

    if (bytesPerFrame == 2) {
        int16_t *samples = (int16_t *)buf->mData;
        for (UInt32 i = 0; i < inNumberFrames; i++) {
            int16_t raw = samples[i];
            if (gIsRecordingTest && gTestRecordCount < 480000) {
                gTestRecordBuffer[gTestRecordCount++] = raw;
            }
            if (gEchoEnabled) {
                float x = (float)raw / 32768.0f;
                float out = applyWarSingleSample(x, gEchoBuffer, &gEchoWritePos, &gLowPassState);
                samples[i] = (int16_t)(out * 32767.0f);
            }
        }
    } else if (bytesPerFrame == 4) {
        float *samples = (float *)buf->mData;
        for (UInt32 i = 0; i < inNumberFrames; i++) {
            float rawF = samples[i];
            if (gIsRecordingTest && gTestRecordCount < 480000) {
                float clamped = rawF;
                if (clamped > 1.0f) clamped = 1.0f;
                if (clamped < -1.0f) clamped = -1.0f;
                gTestRecordBuffer[gTestRecordCount++] = (int16_t)(clamped * 32767.0f);
            }
            if (gEchoEnabled) {
                samples[i] = applyWarSingleSample(rawF, gEchoBuffer, &gEchoWritePos, &gLowPassState);
            }
        }
    }
}

static OSStatus hook_AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (status == noErr && inBusNumber == 1 && (gEchoEnabled || gIsRecordingTest)) {
        processMicEcho(ioData, inNumberFrames);
    }
    return status;
}

typedef struct {
    const void *replacement;
    const void *original;
} InterposeTuple;

__attribute__((used, section("__DATA,__interpose")))
static const InterposeTuple interpose_audio[] = {
    { (const void *)hook_AudioUnitRender, (const void *)AudioUnitRender }
};

static NSData *buildProcessedWavData(void) {
    if (gTestRecordCount <= 0) return nil;
    int tailSamples = 48000;
    int totalSamples = gTestRecordCount + tailSamples;
    int16_t *outPcm = (int16_t *)calloc(totalSamples, sizeof(int16_t));
    float *tempEcho = (float *)calloc(48000, sizeof(float));
    if (!outPcm || !tempEcho) {
        if (outPcm) free(outPcm);
        if (tempEcho) free(tempEcho);
        return nil;
    }

    int wp = 0;
    float lp = 0.0f;
    for (int i = 0; i < totalSamples; i++) {
        float x = (i < gTestRecordCount) ? ((float)gTestRecordBuffer[i] / 32768.0f) : 0.0f;
        float y = applyWarSingleSample(x, tempEcho, &wp, &lp);
        outPcm[i] = (int16_t)(y * 32767.0f);
    }

    uint32_t dataSize = (uint32_t)(totalSamples * 2);
    uint32_t chunkSize = 36 + dataSize;
    uint32_t sampleRate = 48000;
    uint32_t byteRate = sampleRate * 2;
    uint16_t blockAlign = 2;
    uint16_t bitsPerSample = 16;
    uint16_t audioFormat = 1;
    uint16_t numChannels = 1;
    uint32_t subchunk1Size = 16;

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataSize];
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&chunkSize length:4];
    [wav appendBytes:"WAVE" length:4];
    [wav appendBytes:"fmt " length:4];
    [wav appendBytes:&subchunk1Size length:4];
    [wav appendBytes:&audioFormat length:2];
    [wav appendBytes:&numChannels length:2];
    [wav appendBytes:&sampleRate length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&blockAlign length:2];
    [wav appendBytes:&bitsPerSample length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataSize length:4];
    [wav appendBytes:outPcm length:dataSize];

    free(outPcm);
    free(tempEcho);
    return wav;
}

@interface DiscordMenu : NSObject <UIGestureRecognizerDelegate, AVAudioPlayerDelegate>
@property (nonatomic, strong) UIView *box;
@property (nonatomic, strong) UIButton *collapsedMicBtn;
@property (nonatomic, strong) UIImageView *collapsedMicIcon;
@property (nonatomic, strong) UIView *mainContainer;
@property (nonatomic, strong) UIView *slot1;
@property (nonatomic, strong) UIImageView *headerMicIcon;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *slot2;
@property (nonatomic, strong) UILabel *echoTitleLabel;
@property (nonatomic, strong) UISwitch *echoSwitch;
@property (nonatomic, strong) UIImageView *arrowIcon;
@property (nonatomic, strong) UIView *soundPanel;
@property (nonatomic, strong) UILabel *soundHeaderLabel;
@property (nonatomic, strong) UIButton *btnVang;
@property (nonatomic, strong) UIButton *btnGain;
@property (nonatomic, strong) UIView *nganRowBox;
@property (nonatomic, strong) UILabel *nganLabel;
@property (nonatomic, strong) UISwitch *nganSwitch;
@property (nonatomic, strong) UIButton *btnBass;
@property (nonatomic, strong) UISlider *verticalSlider;
@property (nonatomic, strong) UILabel *sliderValueLabel;
@property (nonatomic, strong) UIView *testMicBox;
@property (nonatomic, strong) UILabel *testMicLabel;
@property (nonatomic, strong) NSMutableArray<UIView *> *waveBars;
@property (nonatomic, strong) UIButton *recBtn;
@property (nonatomic, strong) UIButton *playBtn;
@property (nonatomic, strong) AVAudioRecorder *backupRecorder;
@property (nonatomic, strong) AVAudioPlayer *testPlayer;
@property (nonatomic, strong) NSMutableArray<UIView *> *emptySlots;
@property (nonatomic, strong) NSMutableArray<UILabel *> *emptyLabels;
@property (nonatomic, assign) CGFloat hue;
@property (nonatomic, assign) CGFloat wavePhase;
@property (nonatomic, assign) BOOL isExpanded;
@property (nonatomic, assign) BOOL isSoundOpen;
@property (nonatomic, assign) int selectedParam;
+ (instancetype)shared;
- (void)setup;
- (void)layoutMenuAnimated:(BOOL)animated;
- (void)updateParamTitles;
- (void)checkMic;
- (void)updateColor;
- (void)onToggleExpand;
- (void)onToggleSoundPanel;
- (void)onEchoSwitch:(UISwitch *)sender;
- (void)onNganSwitch:(UISwitch *)sender;
- (void)onSelectSliderParam:(UIButton *)sender;
- (void)onVerticalSliderChanged:(UISlider *)sender;
- (void)onTapRecordTest;
- (void)onTapPlayTest;
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

    self.hue = 0.0;
    self.wavePhase = 0.0;
    self.isExpanded = NO;
    self.isSoundOpen = NO;
    self.selectedParam = 1;
    self.waveBars = [NSMutableArray array];
    self.emptySlots = [NSMutableArray array];
    self.emptyLabels = [NSMutableArray array];

    self.box = [[UIView alloc] initWithFrame:CGRectMake(50, 130, 60, 60)];
    self.box.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.11 alpha:0.96];
    self.box.layer.cornerRadius = 16.0;
    self.box.layer.masksToBounds = YES;
    self.box.layer.borderWidth = 2.2;
    self.box.layer.zPosition = 9999;
    self.box.hidden = YES;

    self.collapsedMicBtn = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
    [self.collapsedMicBtn addTarget:self action:@selector(onToggleExpand) forControlEvents:UIControlEventTouchUpInside];
    [self.box addSubview:self.collapsedMicBtn];

    UIImageSymbolConfiguration *micCfg = [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightBold];
    UIImage *micImg = [UIImage systemImageNamed:@"mic.fill" withConfiguration:micCfg];
    self.collapsedMicIcon = [[UIImageView alloc] initWithImage:micImg];
    self.collapsedMicIcon.frame = CGRectMake(13, 13, 34, 34);
    self.collapsedMicIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.collapsedMicIcon.userInteractionEnabled = NO;
    [self.collapsedMicBtn addSubview:self.collapsedMicIcon];

    self.mainContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 226, 300)];
    self.mainContainer.alpha = 0.0;
    [self.box addSubview:self.mainContainer];

    self.slot1 = [[UIView alloc] initWithFrame:CGRectMake(8, 8, 210, 34)];
    self.slot1.backgroundColor = [UIColor colorWithRed:0.14 green:0.15 blue:0.18 alpha:1.0];
    self.slot1.layer.cornerRadius = 8.0;
    self.slot1.layer.borderWidth = 1.2;
    [self.mainContainer addSubview:self.slot1];

    self.headerMicIcon = [[UIImageView alloc] initWithImage:micImg];
    self.headerMicIcon.frame = CGRectMake(10, 7, 20, 20);
    self.headerMicIcon.contentMode = UIViewContentModeScaleAspectFit;
    [self.slot1 addSubview:self.headerMicIcon];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(35, 2, 140, 30)];
    self.titleLabel.text = @"MENU";
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightHeavy];
    [self.slot1 addSubview:self.titleLabel];

    UIButton *closeHeaderBtn = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 210, 34)];
    [closeHeaderBtn addTarget:self action:@selector(onToggleExpand) forControlEvents:UIControlEventTouchUpInside];
    [self.slot1 addSubview:closeHeaderBtn];

    self.slot2 = [[UIView alloc] initWithFrame:CGRectMake(8, 47, 210, 46)];
    self.slot2.backgroundColor = [UIColor colorWithRed:0.14 green:0.15 blue:0.18 alpha:1.0];
    self.slot2.layer.cornerRadius = 8.0;
    self.slot2.layer.borderWidth = 1.2;
    [self.mainContainer addSubview:self.slot2];

    self.echoTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 5, 120, 24)];
    self.echoTitleLabel.text = @"Giọng Vang";
    self.echoTitleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.slot2 addSubview:self.echoTitleLabel];

    self.echoSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(150, 2, 51, 31)];
    self.echoSwitch.transform = CGAffineTransformMakeScale(0.75, 0.75);
    self.echoSwitch.on = NO;
    [self.echoSwitch addTarget:self action:@selector(onEchoSwitch:) forControlEvents:UIControlEventValueChanged];
    [self.slot2 addSubview:self.echoSwitch];

    UIImageSymbolConfiguration *arrowCfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
    UIImage *arrowImg = [UIImage systemImageNamed:@"chevron.down" withConfiguration:arrowCfg];
    self.arrowIcon = [[UIImageView alloc] initWithImage:arrowImg];
    self.arrowIcon.frame = CGRectMake(98, 31, 14, 13);
    self.arrowIcon.contentMode = UIViewContentModeScaleAspectFit;
    [self.slot2 addSubview:self.arrowIcon];

    UIButton *arrowBtn = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 145, 46)];
    [arrowBtn addTarget:self action:@selector(onToggleSoundPanel) forControlEvents:UIControlEventTouchUpInside];
    [self.slot2 addSubview:arrowBtn];

    UIButton *bottomArrowBtn = [[UIButton alloc] initWithFrame:CGRectMake(60, 26, 90, 20)];
    [bottomArrowBtn addTarget:self action:@selector(onToggleSoundPanel) forControlEvents:UIControlEventTouchUpInside];
    [self.slot2 addSubview:bottomArrowBtn];

    self.soundPanel = [[UIView alloc] initWithFrame:CGRectMake(8, 98, 210, 192)];
    self.soundPanel.backgroundColor = [UIColor colorWithRed:0.11 green:0.12 blue:0.15 alpha:1.0];
    self.soundPanel.layer.cornerRadius = 8.0;
    self.soundPanel.layer.borderWidth = 1.2;
    self.soundPanel.layer.masksToBounds = YES;
    self.soundPanel.alpha = 0.0;
    [self.mainContainer addSubview:self.soundPanel];

    self.soundHeaderLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, 210, 16)];
    self.soundHeaderLabel.text = @"CHỈNH ÂM THANH";
    self.soundHeaderLabel.textAlignment = NSTextAlignmentCenter;
    self.soundHeaderLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy];
    [self.soundPanel addSubview:self.soundHeaderLabel];

    self.btnVang = [UIButton buttonWithType:UIButtonTypeCustom];
    self.btnVang.frame = CGRectMake(8, 23, 142, 28);
    self.btnVang.backgroundColor = [UIColor colorWithRed:0.16 green:0.17 blue:0.21 alpha:1.0];
    self.btnVang.layer.cornerRadius = 6.0;
    self.btnVang.layer.borderWidth = 2.0;
    self.btnVang.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    self.btnVang.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.btnVang.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    self.btnVang.tag = 1;
    [self.btnVang addTarget:self action:@selector(onSelectSliderParam:) forControlEvents:UIControlEventTouchUpInside];
    [self.soundPanel addSubview:self.btnVang];

    self.btnGain = [UIButton buttonWithType:UIButtonTypeCustom];
    self.btnGain.frame = CGRectMake(8, 55, 142, 28);
    self.btnGain.backgroundColor = [UIColor colorWithRed:0.16 green:0.17 blue:0.21 alpha:1.0];
    self.btnGain.layer.cornerRadius = 6.0;
    self.btnGain.layer.borderWidth = 0.7;
    self.btnGain.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    self.btnGain.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.btnGain.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    self.btnGain.tag = 2;
    [self.btnGain addTarget:self action:@selector(onSelectSliderParam:) forControlEvents:UIControlEventTouchUpInside];
    [self.soundPanel addSubview:self.btnGain];

    self.nganRowBox = [[UIView alloc] initWithFrame:CGRectMake(8, 87, 142, 28)];
    self.nganRowBox.backgroundColor = [UIColor colorWithRed:0.16 green:0.17 blue:0.21 alpha:1.0];
    self.nganRowBox.layer.cornerRadius = 6.0;
    self.nganRowBox.layer.borderWidth = 0.7;
    [self.soundPanel addSubview:self.nganRowBox];

    self.nganLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 85, 28)];
    self.nganLabel.text = @"3. Độ Ngân";
    self.nganLabel.font = [UIFont boldSystemFontOfSize:11];
    [self.nganRowBox addSubview:self.nganLabel];

    self.nganSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(92, -1, 51, 31)];
    self.nganSwitch.transform = CGAffineTransformMakeScale(0.62, 0.62);
    self.nganSwitch.on = YES;
    [self.nganSwitch addTarget:self action:@selector(onNganSwitch:) forControlEvents:UIControlEventValueChanged];
    [self.nganRowBox addSubview:self.nganSwitch];

    self.btnBass = [UIButton buttonWithType:UIButtonTypeCustom];
    self.btnBass.frame = CGRectMake(8, 119, 142, 28);
    self.btnBass.backgroundColor = [UIColor colorWithRed:0.16 green:0.17 blue:0.21 alpha:1.0];
    self.btnBass.layer.cornerRadius = 6.0;
    self.btnBass.layer.borderWidth = 0.7;
    self.btnBass.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    self.btnBass.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.btnBass.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    self.btnBass.tag = 4;
    [self.btnBass addTarget:self action:@selector(onSelectSliderParam:) forControlEvents:UIControlEventTouchUpInside];
    [self.soundPanel addSubview:self.btnBass];

    self.sliderValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(150, 22, 56, 16)];
    self.sliderValueLabel.textAlignment = NSTextAlignmentCenter;
    self.sliderValueLabel.font = [UIFont boldSystemFontOfSize:10];
    [self.soundPanel addSubview:self.sliderValueLabel];

    self.verticalSlider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 106, 28)];
    self.verticalSlider.minimumValue = 0.0f;
    self.verticalSlider.maximumValue = 1.0f;
    self.verticalSlider.value = gParamEcho;
    self.verticalSlider.transform = CGAffineTransformMakeRotation(-1.5707963f);
    self.verticalSlider.center = CGPointMake(179, 93);
    [self.verticalSlider addTarget:self action:@selector(onVerticalSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.soundPanel addSubview:self.verticalSlider];

    self.testMicBox = [[UIView alloc] initWithFrame:CGRectMake(8, 152, 194, 34)];
    self.testMicBox.backgroundColor = [UIColor colorWithRed:0.15 green:0.16 blue:0.20 alpha:1.0];
    self.testMicBox.layer.cornerRadius = 7.0;
    self.testMicBox.layer.borderWidth = 1.0;
    [self.soundPanel addSubview:self.testMicBox];

    self.testMicLabel = [[UILabel alloc] initWithFrame:CGRectMake(7, 0, 52, 34)];
    self.testMicLabel.text = @"Thử Mic";
    self.testMicLabel.font = [UIFont boldSystemFontOfSize:11];
    [self.testMicBox addSubview:self.testMicLabel];

    for (int i = 0; i < 6; i++) {
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(61 + i * 5, 15, 3, 4)];
        bar.layer.cornerRadius = 1.5;
        [self.testMicBox addSubview:bar];
        [self.waveBars addObject:bar];
    }

    UIImageSymbolConfiguration *btnSymCfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
    UIImage *recImg = [UIImage systemImageNamed:@"mic.circle.fill" withConfiguration:btnSymCfg];
    self.recBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.recBtn.frame = CGRectMake(94, 4, 48, 26);
    self.recBtn.backgroundColor = [UIColor colorWithRed:0.22 green:0.23 blue:0.28 alpha:1.0];
    self.recBtn.layer.cornerRadius = 6.0;
    self.recBtn.layer.borderWidth = 1.0;
    [self.recBtn setImage:recImg forState:UIControlStateNormal];
    [self.recBtn setTitle:@" Thu" forState:UIControlStateNormal];
    self.recBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
    [self.recBtn addTarget:self action:@selector(onTapRecordTest) forControlEvents:UIControlEventTouchUpInside];
    [self.testMicBox addSubview:self.recBtn];

    UIImage *playImg = [UIImage systemImageNamed:@"play.circle.fill" withConfiguration:btnSymCfg];
    self.playBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.playBtn.frame = CGRectMake(145, 4, 45, 26);
    self.playBtn.backgroundColor = [UIColor colorWithRed:0.22 green:0.23 blue:0.28 alpha:1.0];
    self.playBtn.layer.cornerRadius = 6.0;
    self.playBtn.layer.borderWidth = 1.0;
    [self.playBtn setImage:playImg forState:UIControlStateNormal];
    [self.playBtn setTitle:@" Phát" forState:UIControlStateNormal];
    self.playBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
    self.playBtn.hidden = YES;
    [self.playBtn addTarget:self action:@selector(onTapPlayTest) forControlEvents:UIControlEventTouchUpInside];
    [self.testMicBox addSubview:self.playBtn];

    for (int i = 0; i < 5; i++) {
        UIView *slot = [[UIView alloc] initWithFrame:CGRectMake(8, 98 + i * 39, 210, 34)];
        slot.backgroundColor = [UIColor colorWithRed:0.14 green:0.15 blue:0.18 alpha:1.0];
        slot.layer.cornerRadius = 8.0;
        slot.layer.borderWidth = 1.0;

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 186, 34)];
        lbl.text = [NSString stringWithFormat:@"Ngăn %d (Chờ thêm...)", i + 3];
        lbl.font = [UIFont boldSystemFontOfSize:13];
        [slot addSubview:lbl];

        [self.mainContainer addSubview:slot];
        [self.emptySlots addObject:slot];
        [self.emptyLabels addObject:lbl];
    }

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    pan.delegate = self;
    [self.box addGestureRecognizer:pan];

    [win addSubview:self.box];

    [self updateParamTitles];
    [self layoutMenuAnimated:NO];
    [self updateColor];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(checkMic) name:AVAudioSessionRouteChangeNotification object:nil];
    [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(checkMic) userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:0.04 target:self selector:@selector(updateColor) userInfo:nil repeats:YES];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *v = touch.view;
    while (v && v != self.box) {
        if ([v isKindOfClass:[UISlider class]] || [v isKindOfClass:[UISwitch class]] || [v isKindOfClass:[UIButton class]]) {
            return NO;
        }
        v = v.superview;
    }
    return YES;
}

- (void)updateParamTitles {
    int vangPct = (int)(gParamEcho * 1000.0f);
    int gainPct = (int)(gParamGain * 2000.0f);
    int bassPct = (int)(gParamBass * 2000.0f);

    [self.btnVang setTitle:[NSString stringWithFormat:@"1. Độ Vang: %d%%", vangPct] forState:UIControlStateNormal];
    [self.btnGain setTitle:[NSString stringWithFormat:@"2. Khuếch Đại: %d%%", gainPct] forState:UIControlStateNormal];
    [self.btnBass setTitle:[NSString stringWithFormat:@"4. Bass: %d%%", bassPct] forState:UIControlStateNormal];

    int curPct = vangPct;
    if (self.selectedParam == 2) curPct = gainPct;
    if (self.selectedParam == 4) curPct = bassPct;
    self.sliderValueLabel.text = [NSString stringWithFormat:@"%d%%", curPct];
}

- (void)onEchoSwitch:(UISwitch *)sender {
    gEchoEnabled = sender.isOn;
}

- (void)onNganSwitch:(UISwitch *)sender {
    gLongNganEnabled = sender.isOn;
}

- (void)onSelectSliderParam:(UIButton *)sender {
    self.selectedParam = (int)sender.tag;
    if (self.selectedParam == 1) self.verticalSlider.value = gParamEcho;
    if (self.selectedParam == 2) self.verticalSlider.value = gParamGain;
    if (self.selectedParam == 4) self.verticalSlider.value = gParamBass;

    self.btnVang.layer.borderWidth = (self.selectedParam == 1) ? 2.0 : 0.7;
    self.btnGain.layer.borderWidth = (self.selectedParam == 2) ? 2.0 : 0.7;
    self.btnBass.layer.borderWidth = (self.selectedParam == 4) ? 2.0 : 0.7;

    [self updateParamTitles];
}

- (void)onVerticalSliderChanged:(UISlider *)sender {
    if (self.selectedParam == 1) gParamEcho = sender.value;
    if (self.selectedParam == 2) gParamGain = sender.value;
    if (self.selectedParam == 4) gParamBass = sender.value;
    [self updateParamTitles];
}

- (void)onTapRecordTest {
    UIImageSymbolConfiguration *btnSymCfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
    if (!gIsRecordingTest) {
        if (self.testPlayer && self.testPlayer.isPlaying) {
            [self.testPlayer stop];
        }
        gTestRecordCount = 0;
        gIsRecordingTest = YES;
        self.playBtn.hidden = YES;

        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"test_war_mic.wav"];
        NSURL *url = [NSURL fileURLWithPath:tempPath];
        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @(48000.0),
            AVNumberOfChannelsKey: @(1),
            AVLinearPCMBitDepthKey: @(16),
            AVLinearPCMIsBigEndianKey: @(NO),
            AVLinearPCMIsFloatKey: @(NO)
        };
        self.backupRecorder = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:nil];
        [self.backupRecorder prepareToRecord];
        [self.backupRecorder record];

        UIImage *stopImg = [UIImage systemImageNamed:@"stop.circle.fill" withConfiguration:btnSymCfg];
        [self.recBtn setImage:stopImg forState:UIControlStateNormal];
        [self.recBtn setTitle:@" Ngừng" forState:UIControlStateNormal];
    } else {
        gIsRecordingTest = NO;
        if (self.backupRecorder) {
            [self.backupRecorder stop];
            if (gTestRecordCount < 2400) {
                NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"test_war_mic.wav"];
                NSData *rawFile = [NSData dataWithContentsOfFile:tempPath];
                if (rawFile && rawFile.length > 44) {
                    int numSamples = (int)((rawFile.length - 44) / 2);
                    if (numSamples > 480000) numSamples = 480000;
                    memcpy(gTestRecordBuffer, (const char *)rawFile.bytes + 44, numSamples * 2);
                    gTestRecordCount = numSamples;
                }
            }
            self.backupRecorder = nil;
        }

        UIImage *recImg = [UIImage systemImageNamed:@"mic.circle.fill" withConfiguration:btnSymCfg];
        [self.recBtn setImage:recImg forState:UIControlStateNormal];
        [self.recBtn setTitle:@" Thu" forState:UIControlStateNormal];

        if (gTestRecordCount > 0) {
            self.playBtn.hidden = NO;
        }
    }
}

- (void)onTapPlayTest {
    UIImageSymbolConfiguration *btnSymCfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
    if (self.testPlayer && self.testPlayer.isPlaying) {
        [self.testPlayer stop];
        UIImage *playImg = [UIImage systemImageNamed:@"play.circle.fill" withConfiguration:btnSymCfg];
        [self.playBtn setImage:playImg forState:UIControlStateNormal];
        [self.playBtn setTitle:@" Phát" forState:UIControlStateNormal];
        return;
    }

    NSData *wavData = buildProcessedWavData();
    if (!wavData) return;

    self.testPlayer = [[AVAudioPlayer alloc] initWithData:wavData error:nil];
    self.testPlayer.delegate = self;
    self.testPlayer.volume = 1.0f;
    [self.testPlayer prepareToPlay];
    [self.testPlayer play];

    UIImage *stopImg = [UIImage systemImageNamed:@"pause.circle.fill" withConfiguration:btnSymCfg];
    [self.playBtn setImage:stopImg forState:UIControlStateNormal];
    [self.playBtn setTitle:@" Dừng" forState:UIControlStateNormal];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    UIImageSymbolConfiguration *btnSymCfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
    UIImage *playImg = [UIImage systemImageNamed:@"play.circle.fill" withConfiguration:btnSymCfg];
    [self.playBtn setImage:playImg forState:UIControlStateNormal];
    [self.playBtn setTitle:@" Phát" forState:UIControlStateNormal];
}

- (void)onToggleExpand {
    self.isExpanded = !self.isExpanded;
    [self layoutMenuAnimated:YES];
}

- (void)onToggleSoundPanel {
    self.isSoundOpen = !self.isSoundOpen;
    UIImageSymbolConfiguration *arrowCfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
    NSString *sym = self.isSoundOpen ? @"chevron.up" : @"chevron.down";
    self.arrowIcon.image = [UIImage systemImageNamed:sym withConfiguration:arrowCfg];
    [self layoutMenuAnimated:YES];
}

- (void)layoutMenuAnimated:(BOOL)animated {
    CGPoint currentCenter = self.box.center;
    void (^applyLayout)(void) = ^{
        if (!self.isExpanded) {
            self.box.bounds = CGRectMake(0, 0, 60, 60);
            self.box.center = currentCenter;
            self.box.layer.cornerRadius = 16.0;
            self.collapsedMicBtn.alpha = 1.0;
            self.mainContainer.alpha = 0.0;
        } else {
            CGFloat y = 98.0;
            if (self.isSoundOpen) {
                self.soundPanel.frame = CGRectMake(8, 98, 210, 192);
                self.soundPanel.alpha = 1.0;
                y = 295.0;
            } else {
                self.soundPanel.frame = CGRectMake(8, 98, 210, 0);
                self.soundPanel.alpha = 0.0;
            }
            for (int i = 0; i < 5; i++) {
                UIView *slot = self.emptySlots[i];
                slot.frame = CGRectMake(8, y, 210, 34);
                y += 39.0;
            }
            CGFloat totalH = y + 3.0;
            self.mainContainer.frame = CGRectMake(0, 0, 226, totalH);
            self.box.bounds = CGRectMake(0, 0, 226, totalH);
            self.box.center = currentCenter;
            self.box.layer.cornerRadius = 18.0;
            self.collapsedMicBtn.alpha = 0.0;
            self.mainContainer.alpha = 1.0;
        }
    };

    if (animated) {
        [UIView animateWithDuration:0.25 animations:applyLayout];
    } else {
        applyLayout();
    }
}

- (void)updateColor {
    self.hue += 0.01;
    if (self.hue > 1.0) {
        self.hue = 0.0;
    }
    self.wavePhase += 0.35;

    CGFloat h2 = self.hue + 0.15;
    if (h2 > 1.0) h2 -= 1.0;
    CGFloat h3 = self.hue + 0.32;
    if (h3 > 1.0) h3 -= 1.0;
    CGFloat h4 = self.hue + 0.50;
    if (h4 > 1.0) h4 -= 1.0;

    UIColor *rgb1 = [UIColor colorWithHue:self.hue saturation:0.88 brightness:1.0 alpha:1.0];
    UIColor *rgb2 = [UIColor colorWithHue:h2 saturation:0.88 brightness:1.0 alpha:1.0];
    UIColor *rgb3 = [UIColor colorWithHue:h3 saturation:0.88 brightness:1.0 alpha:1.0];
    UIColor *rgb4 = [UIColor colorWithHue:h4 saturation:0.88 brightness:1.0 alpha:1.0];

    self.box.layer.borderColor = rgb1.CGColor;
    self.collapsedMicIcon.tintColor = rgb1;
    self.headerMicIcon.tintColor = rgb1;
    self.titleLabel.textColor = rgb1;
    self.slot1.layer.borderColor = rgb1.CGColor;

    self.slot2.layer.borderColor = rgb2.CGColor;
    self.echoTitleLabel.textColor = rgb2;
    self.arrowIcon.tintColor = rgb2;
    self.echoSwitch.onTintColor = rgb1;

    self.soundPanel.layer.borderColor = rgb1.CGColor;
    self.soundHeaderLabel.textColor = rgb3;
    self.verticalSlider.minimumTrackTintColor = rgb1;
    self.sliderValueLabel.textColor = rgb2;

    [self.btnVang setTitleColor:rgb1 forState:UIControlStateNormal];
    self.btnVang.layer.borderColor = (self.selectedParam == 1) ? rgb1.CGColor : rgb3.CGColor;

    [self.btnGain setTitleColor:rgb2 forState:UIControlStateNormal];
    self.btnGain.layer.borderColor = (self.selectedParam == 2) ? rgb2.CGColor : rgb3.CGColor;

    self.nganRowBox.layer.borderColor = rgb3.CGColor;
    self.nganLabel.textColor = rgb3;
    self.nganSwitch.onTintColor = rgb3;

    [self.btnBass setTitleColor:rgb4 forState:UIControlStateNormal];
    self.btnBass.layer.borderColor = (self.selectedParam == 4) ? rgb4.CGColor : rgb3.CGColor;

    self.testMicBox.layer.borderColor = rgb2.CGColor;
    self.testMicLabel.textColor = rgb1;

    [self.recBtn setTitleColor:rgb2 forState:UIControlStateNormal];
    self.recBtn.tintColor = rgb2;
    self.recBtn.layer.borderColor = rgb2.CGColor;

    [self.playBtn setTitleColor:rgb4 forState:UIControlStateNormal];
    self.playBtn.tintColor = rgb4;
    self.playBtn.layer.borderColor = rgb4.CGColor;

    BOOL activeWave = gIsRecordingTest || (self.testPlayer && self.testPlayer.isPlaying);
    for (int i = 0; i < 6; i++) {
        UIView *bar = self.waveBars[i];
        CGFloat bh = 4.0;
        if (activeWave) {
            CGFloat s = sin(self.wavePhase + i * 0.9);
            if (s < 0) s = -s;
            bh = 4.0 + s * 18.0;
        }
        bar.frame = CGRectMake(61 + i * 5, 17.0 - (bh * 0.5), 3.0, bh);
        bar.backgroundColor = (i % 2 == 0) ? rgb1 : rgb3;
    }

    for (int i = 0; i < 5; i++) {
        CGFloat hs = self.hue + (i * 0.12);
        if (hs > 1.0) hs -= 1.0;
        UIColor *slotRgb = [UIColor colorWithHue:hs saturation:0.85 brightness:1.0 alpha:1.0];
        self.emptySlots[i].layer.borderColor = slotRgb.CGColor;
        self.emptyLabels[i].textColor = slotRgb;
    }
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
