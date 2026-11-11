@import UIKit;
@import Foundation;
@import CoreGraphics;
@import QuartzCore;
@import AVFoundation;
@import AudioToolbox;

struct my_mach_header_64 {
    uint32_t magic;
    int32_t cputype;
    int32_t cpusubtype;
    uint32_t filetype;
    uint32_t ncmds;
    uint32_t sizeofcmds;
    uint32_t flags;
    uint32_t reserved;
};

struct my_load_command {
    uint32_t cmd;
    uint32_t cmdsize;
};

struct my_segment_command_64 {
    uint32_t cmd;
    uint32_t cmdsize;
    char segname[16];
    uint64_t vmaddr;
    uint64_t vmsize;
    uint64_t fileoff;
    uint64_t filesize;
    int32_t maxprot;
    int32_t initprot;
    uint32_t nsects;
    uint32_t flags;
};

struct my_section_64 {
    char sectname[16];
    char segname[16];
    uint64_t addr;
    uint64_t size;
    uint32_t offset;
    uint32_t align;
    uint32_t reloff;
    uint32_t nreloc;
    uint32_t flags;
    uint32_t reserved1;
    uint32_t reserved2;
    uint32_t reserved3;
};

struct my_symtab_command {
    uint32_t cmd;
    uint32_t cmdsize;
    uint32_t symoff;
    uint32_t nsyms;
    uint32_t stroff;
    uint32_t strsize;
};

struct my_dysymtab_command {
    uint32_t cmd;
    uint32_t cmdsize;
    uint32_t ilocalsym;
    uint32_t nlocalsym;
    uint32_t iextdefsym;
    uint32_t nextdefsym;
    uint32_t iundefsym;
    uint32_t nundefsym;
    uint32_t tocoff;
    uint32_t ntoc;
    uint32_t modtaboff;
    uint32_t nmodtab;
    uint32_t extrefsymoff;
    uint32_t nextrefsyms;
    uint32_t indirectsymoff;
    uint32_t nindirectsyms;
    uint32_t exprelocoff;
    uint32_t nlocreloc;
    uint32_t locrelocoff;
};

struct my_nlist_64 {
    uint32_t n_strx;
    uint8_t n_type;
    uint8_t n_sect;
    uint16_t n_desc;
    uint64_t n_value;
};

extern uint32_t _dyld_image_count(void);
extern const struct my_mach_header_64 *_dyld_get_image_header(uint32_t image_index);
extern intptr_t _dyld_get_image_vmaddr_slide(uint32_t image_index);
extern const char *_dyld_get_image_name(uint32_t image_index);
extern unsigned int mach_task_self_;
extern int vm_protect(unsigned int target_task, uintptr_t address, uintptr_t size, int set_maximum, int new_protection);

static BOOL gEchoEnabled = NO;
static float gParamEcho = 0.50f;
static float gParamGain = 0.25f;
static BOOL gLongNganEnabled = YES;
static float gParamBass = 0.30f;

static float gEchoBuffer[48000];
static int gEchoWritePos = 0;
static float gBassLP = 0.0f;
static float gEchoDampLP = 0.0f;

static float cleanStudioSample(float x) {
    float echoMix = gParamEcho * 0.85f;
    float preGain = 1.0f + (gParamGain * 2.5f);
    float bassGain = gParamBass * 1.4f;
    float feedback = gLongNganEnabled ? 0.52f : 0.22f;

    int d1 = gLongNganEnabled ? 7200 : 4800;
    int d2 = gLongNganEnabled ? 14400 : 9600;
    int d3 = gLongNganEnabled ? 21600 : 14400;

    gBassLP = gBassLP + 0.045f * (x - gBassLP);
    float warmVoice = x + (gBassLP * bassGain);

    int wp = gEchoWritePos;
    int r1 = (wp + 48000 - d1) % 48000;
    int r2 = (wp + 48000 - d2) % 48000;
    int r3 = (wp + 48000 - d3) % 48000;

    float rawEcho = gEchoBuffer[r1] * 0.50f + gEchoBuffer[r2] * 0.30f + gEchoBuffer[r3] * 0.15f;
    gEchoDampLP = gEchoDampLP + 0.35f * (rawEcho - gEchoDampLP);

    float nextBuf = x * 0.85f + gEchoDampLP * feedback;
    nextBuf = tanhf(nextBuf);
    gEchoBuffer[wp] = nextBuf;
    gEchoWritePos = (wp + 1) % 48000;

    float combined = (warmVoice + gEchoDampLP * echoMix) * preGain;
    return tanhf(combined);
}

static void processMicEcho(AudioBufferList *ioData, UInt32 inNumberFrames) {
    if (!gEchoEnabled || !ioData || ioData->mNumberBuffers == 0 || inNumberFrames == 0) return;

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        AudioBuffer *buf = &ioData->mBuffers[b];
        if (!buf->mData || buf->mDataByteSize == 0) continue;

        UInt32 bytesPerFrame = buf->mDataByteSize / inNumberFrames;

        if (bytesPerFrame == 2) {
            int16_t *samples = (int16_t *)buf->mData;
            for (UInt32 i = 0; i < inNumberFrames; i++) {
                float x = (float)samples[i] / 32768.0f;
                float out = cleanStudioSample(x);
                samples[i] = (int16_t)(out * 32760.0f);
            }
        } else if (bytesPerFrame == 4) {
            float *samples = (float *)buf->mData;
            for (UInt32 i = 0; i < inNumberFrames; i++) {
                samples[i] = cleanStudioSample(samples[i]);
            }
        }
    }
}

static OSStatus hook_AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (status == noErr && inBusNumber == 1 && gEchoEnabled) {
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

static void hookGotPointers(void) {
    uintptr_t origAddr = ((uintptr_t)AudioUnitRender) & 0x0000007fffffffffULL;
    void *hookFunc = (void *)hook_AudioUnitRender;
    uint32_t count = _dyld_image_count();

    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (!strstr(name, ".app/") || strstr(name, "MenuDiscord")) continue;

        const struct my_mach_header_64 *header = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (!header || header->magic != 0xfeedfacf) continue;

        struct my_segment_command_64 *linkedit_seg = NULL;
        struct my_symtab_command *symtab_cmd = NULL;
        struct my_dysymtab_command *dysymtab_cmd = NULL;

        uintptr_t cur = (uintptr_t)header + sizeof(struct my_mach_header_64);
        for (uint32_t c = 0; c < header->ncmds; c++) {
            struct my_load_command *lc = (struct my_load_command *)cur;
            if (lc->cmd == 0x19) {
                struct my_segment_command_64 *seg = (struct my_segment_command_64 *)cur;
                if (strcmp(seg->segname, "__LINKEDIT") == 0) {
                    linkedit_seg = seg;
                }
            } else if (lc->cmd == 0x2) {
                symtab_cmd = (struct my_symtab_command *)cur;
            } else if (lc->cmd == 0xb) {
                dysymtab_cmd = (struct my_dysymtab_command *)cur;
            }
            cur += lc->cmdsize;
        }

        struct my_nlist_64 *symtab = NULL;
        const char *strtab = NULL;
        uint32_t *indirect_symtab = NULL;

        if (linkedit_seg && symtab_cmd && dysymtab_cmd) {
            uintptr_t linkedit_base = (uintptr_t)slide + (uintptr_t)(linkedit_seg->vmaddr - linkedit_seg->fileoff);
            symtab = (struct my_nlist_64 *)(linkedit_base + symtab_cmd->symoff);
            strtab = (const char *)(linkedit_base + symtab_cmd->stroff);
            indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);
        }

        cur = (uintptr_t)header + sizeof(struct my_mach_header_64);
        for (uint32_t c = 0; c < header->ncmds; c++) {
            struct my_load_command *lc = (struct my_load_command *)cur;
            if (lc->cmd == 0x19) {
                struct my_segment_command_64 *seg = (struct my_segment_command_64 *)cur;
                if (strncmp(seg->segname, "__DATA", 6) == 0 || strncmp(seg->segname, "__AUTH", 6) == 0) {
                    struct my_section_64 *sec = (struct my_section_64 *)(cur + sizeof(struct my_segment_command_64));
                    for (uint32_t s = 0; s < seg->nsects; s++) {
                        uint8_t secType = sec[s].flags & 0xff;
                        BOOL isPtrSec = (secType == 0x6 || secType == 0x7 || strstr(sec[s].sectname, "got") || strstr(sec[s].sectname, "symbol_ptr"));
                        if (isPtrSec && sec[s].size > 0) {
                            uintptr_t addr = (uintptr_t)(sec[s].addr + slide);
                            uintptr_t size = (uintptr_t)sec[s].size;
                            if (vm_protect(mach_task_self_, addr, size, 0, 19) == 0) {
                                void **ptrs = (void **)addr;
                                uintptr_t num = size / sizeof(void *);
                                for (uintptr_t k = 0; k < num; k++) {
                                    uintptr_t curPtr = ((uintptr_t)ptrs[k]) & 0x0000007fffffffffULL;
                                    if (curPtr == origAddr) {
                                        ptrs[k] = hookFunc;
                                        continue;
                                    }
                                    if (symtab && strtab && indirect_symtab && (sec[s].reserved1 + k < dysymtab_cmd->nindirectsyms)) {
                                        uint32_t symIdx = indirect_symtab[sec[s].reserved1 + k];
                                        if (symIdx < symtab_cmd->nsyms) {
                                            const char *symName = strtab + symtab[symIdx].n_strx;
                                            if (strcmp(symName, "_AudioUnitRender") == 0) {
                                                ptrs[k] = hookFunc;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            cur += lc->cmdsize;
        }
    }
}

@interface DiscordMenu : NSObject <UIGestureRecognizerDelegate>
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
@property (nonatomic, strong) UISlider *bottomSlider;
@property (nonatomic, strong) NSMutableArray<UIView *> *emptySlots;
@property (nonatomic, strong) NSMutableArray<UILabel *> *emptyLabels;
@property (nonatomic, assign) BOOL isExpanded;
@property (nonatomic, assign) BOOL isSoundOpen;
@property (nonatomic, assign) int selectedParam;
+ (instancetype)shared;
- (void)setup;
- (void)layoutMenuAnimated:(BOOL)animated;
- (void)updateParamTitles;
- (void)checkMic;
- (void)onToggleExpand;
- (void)onToggleSoundPanel;
- (void)onEchoSwitch:(UISwitch *)sender;
- (void)onNganSwitch:(UISwitch *)sender;
- (void)onSelectSliderParam:(UIButton *)sender;
- (void)onBottomSliderChanged:(UISlider *)sender;
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
    hookGotPointers();

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

    self.isExpanded = NO;
    self.isSoundOpen = NO;
    self.selectedParam = 1;
    self.emptySlots = [NSMutableArray array];
    self.emptyLabels = [NSMutableArray array];

    UIColor *bgDark = [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:0.96];
    UIColor *slotBg = [UIColor colorWithRed:0.15 green:0.16 blue:0.19 alpha:1.0];
    UIColor *borderBasic = [UIColor colorWithRed:0.26 green:0.28 blue:0.33 alpha:1.0];
    UIColor *accentColor = [UIColor colorWithRed:0.35 green:0.55 blue:0.95 alpha:1.0];
    UIColor *textMain = [UIColor colorWithWhite:0.92 alpha:1.0];
    UIColor *textSub = [UIColor colorWithWhite:0.60 alpha:1.0];

    self.box = [[UIView alloc] initWithFrame:CGRectMake(50, 140, 46, 46)];
    self.box.backgroundColor = bgDark;
    self.box.layer.cornerRadius = 12.0;
    self.box.layer.masksToBounds = YES;
    self.box.layer.borderWidth = 1.2;
    self.box.layer.borderColor = borderBasic.CGColor;
    self.box.layer.zPosition = 9999;
    self.box.hidden = YES;

    self.collapsedMicBtn = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 46, 46)];
    [self.collapsedMicBtn addTarget:self action:@selector(onToggleExpand) forControlEvents:UIControlEventTouchUpInside];
    [self.box addSubview:self.collapsedMicBtn];

    UIImageSymbolConfiguration *micCfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
    UIImage *micImg = [UIImage systemImageNamed:@"mic.fill" withConfiguration:micCfg];
    self.collapsedMicIcon = [[UIImageView alloc] initWithImage:micImg];
    self.collapsedMicIcon.frame = CGRectMake(11, 11, 24, 24);
    self.collapsedMicIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.collapsedMicIcon.tintColor = textMain;
    self.collapsedMicIcon.userInteractionEnabled = NO;
    [self.collapsedMicBtn addSubview:self.collapsedMicIcon];

    self.mainContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 196, 260)];
    self.mainContainer.alpha = 0.0;
    [self.box addSubview:self.mainContainer];

    self.slot1 = [[UIView alloc] initWithFrame:CGRectMake(8, 8, 180, 28)];
    self.slot1.backgroundColor = slotBg;
    self.slot1.layer.cornerRadius = 6.0;
    self.slot1.layer.borderWidth = 0.8;
    self.slot1.layer.borderColor = borderBasic.CGColor;
    [self.mainContainer addSubview:self.slot1];

    self.headerMicIcon = [[UIImageView alloc] initWithImage:micImg];
    self.headerMicIcon.frame = CGRectMake(8, 6, 16, 16);
    self.headerMicIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.headerMicIcon.tintColor = textMain;
    [self.slot1 addSubview:self.headerMicIcon];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(30, 0, 120, 28)];
    self.titleLabel.text = @"MENU";
    self.titleLabel.textColor = textMain;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [self.slot1 addSubview:self.titleLabel];

    UIButton *closeHeaderBtn = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 180, 28)];
    [closeHeaderBtn addTarget:self action:@selector(onToggleExpand) forControlEvents:UIControlEventTouchUpInside];
    [self.slot1 addSubview:closeHeaderBtn];

    self.slot2 = [[UIView alloc] initWithFrame:CGRectMake(8, 41, 180, 40)];
    self.slot2.backgroundColor = slotBg;
    self.slot2.layer.cornerRadius = 6.0;
    self.slot2.layer.borderWidth = 0.8;
    self.slot2.layer.borderColor = borderBasic.CGColor;
    [self.mainContainer addSubview:self.slot2];

    self.echoTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 4, 110, 20)];
    self.echoTitleLabel.text = @"Giọng Vang";
    self.echoTitleLabel.textColor = textMain;
    self.echoTitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [self.slot2 addSubview:self.echoTitleLabel];

    self.echoSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(126, 0, 51, 31)];
    self.echoSwitch.transform = CGAffineTransformMakeScale(0.68, 0.68);
    self.echoSwitch.on = NO;
    self.echoSwitch.onTintColor = accentColor;
    [self.echoSwitch addTarget:self action:@selector(onEchoSwitch:) forControlEvents:UIControlEventValueChanged];
    [self.slot2 addSubview:self.echoSwitch];

    UIImageSymbolConfiguration *arrowCfg = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightBold];
    UIImage *arrowImg = [UIImage systemImageNamed:@"chevron.down" withConfiguration:arrowCfg];
    self.arrowIcon = [[UIImageView alloc] initWithImage:arrowImg];
    self.arrowIcon.frame = CGRectMake(84, 27, 12, 11);
    self.arrowIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.arrowIcon.tintColor = textSub;
    [self.slot2 addSubview:self.arrowIcon];

    UIButton *arrowBtn = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 125, 40)];
    [arrowBtn addTarget:self action:@selector(onToggleSoundPanel) forControlEvents:UIControlEventTouchUpInside];
    [self.slot2 addSubview:arrowBtn];

    UIButton *bottomArrowBtn = [[UIButton alloc] initWithFrame:CGRectMake(50, 22, 80, 18)];
    [bottomArrowBtn addTarget:self action:@selector(onToggleSoundPanel) forControlEvents:UIControlEventTouchUpInside];
    [self.slot2 addSubview:bottomArrowBtn];

    self.soundPanel = [[UIView alloc] initWithFrame:CGRectMake(8, 86, 180, 162)];
    self.soundPanel.backgroundColor = [UIColor colorWithRed:0.12 green:0.13 blue:0.15 alpha:1.0];
    self.soundPanel.layer.cornerRadius = 6.0;
    self.soundPanel.layer.borderWidth = 0.8;
    self.soundPanel.layer.borderColor = borderBasic.CGColor;
    self.soundPanel.layer.masksToBounds = YES;
    self.soundPanel.alpha = 0.0;
    [self.mainContainer addSubview:self.soundPanel];

    self.soundHeaderLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, 180, 14)];
    self.soundHeaderLabel.text = @"Chỉnh Âm Thanh";
    self.soundHeaderLabel.textColor = textSub;
    self.soundHeaderLabel.textAlignment = NSTextAlignmentCenter;
    self.soundHeaderLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    [self.soundPanel addSubview:self.soundHeaderLabel];

    self.btnVang = [UIButton buttonWithType:UIButtonTypeCustom];
    self.btnVang.frame = CGRectMake(8, 21, 164, 24);
    self.btnVang.backgroundColor = slotBg;
    self.btnVang.layer.cornerRadius = 5.0;
    self.btnVang.layer.borderWidth = 1.2;
    self.btnVang.layer.borderColor = accentColor.CGColor;
    self.btnVang.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [self.btnVang setTitleColor:textMain forState:UIControlStateNormal];
    self.btnVang.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.btnVang.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    self.btnVang.tag = 1;
    [self.btnVang addTarget:self action:@selector(onSelectSliderParam:) forControlEvents:UIControlEventTouchUpInside];
    [self.soundPanel addSubview:self.btnVang];

    self.btnGain = [UIButton buttonWithType:UIButtonTypeCustom];
    self.btnGain.frame = CGRectMake(8, 49, 164, 24);
    self.btnGain.backgroundColor = slotBg;
    self.btnGain.layer.cornerRadius = 5.0;
    self.btnGain.layer.borderWidth = 0.6;
    self.btnGain.layer.borderColor = borderBasic.CGColor;
    self.btnGain.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [self.btnGain setTitleColor:textMain forState:UIControlStateNormal];
    self.btnGain.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.btnGain.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    self.btnGain.tag = 2;
    [self.btnGain addTarget:self action:@selector(onSelectSliderParam:) forControlEvents:UIControlEventTouchUpInside];
    [self.soundPanel addSubview:self.btnGain];

    self.nganRowBox = [[UIView alloc] initWithFrame:CGRectMake(8, 77, 164, 24)];
    self.nganRowBox.backgroundColor = slotBg;
    self.nganRowBox.layer.cornerRadius = 5.0;
    self.nganRowBox.layer.borderWidth = 0.6;
    self.nganRowBox.layer.borderColor = borderBasic.CGColor;
    [self.soundPanel addSubview:self.nganRowBox];

    self.nganLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 100, 24)];
    self.nganLabel.text = @"3. Độ Ngân";
    self.nganLabel.textColor = textMain;
    self.nganLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [self.nganRowBox addSubview:self.nganLabel];

    self.nganSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(114, -3, 51, 31)];
    self.nganSwitch.transform = CGAffineTransformMakeScale(0.58, 0.58);
    self.nganSwitch.on = YES;
    self.nganSwitch.onTintColor = accentColor;
    [self.nganSwitch addTarget:self action:@selector(onNganSwitch:) forControlEvents:UIControlEventValueChanged];
    [self.nganRowBox addSubview:self.nganSwitch];

    self.btnBass = [UIButton buttonWithType:UIButtonTypeCustom];
    self.btnBass.frame = CGRectMake(8, 105, 164, 24);
    self.btnBass.backgroundColor = slotBg;
    self.btnBass.layer.cornerRadius = 5.0;
    self.btnBass.layer.borderWidth = 0.6;
    self.btnBass.layer.borderColor = borderBasic.CGColor;
    self.btnBass.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [self.btnBass setTitleColor:textMain forState:UIControlStateNormal];
    self.btnBass.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.btnBass.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    self.btnBass.tag = 4;
    [self.btnBass addTarget:self action:@selector(onSelectSliderParam:) forControlEvents:UIControlEventTouchUpInside];
    [self.soundPanel addSubview:self.btnBass];

    self.bottomSlider = [[UISlider alloc] initWithFrame:CGRectMake(10, 133, 160, 24)];
    self.bottomSlider.minimumValue = 0.0f;
    self.bottomSlider.maximumValue = 1.0f;
    self.bottomSlider.value = gParamEcho;
    self.bottomSlider.minimumTrackTintColor = accentColor;
    [self.bottomSlider addTarget:self action:@selector(onBottomSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.soundPanel addSubview:self.bottomSlider];

    for (int i = 0; i < 5; i++) {
        UIView *slot = [[UIView alloc] initWithFrame:CGRectMake(8, 86 + i * 33, 180, 28)];
        slot.backgroundColor = slotBg;
        slot.layer.cornerRadius = 6.0;
        slot.layer.borderWidth = 0.8;
        slot.layer.borderColor = borderBasic.CGColor;

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, 160, 28)];
        lbl.text = [NSString stringWithFormat:@"Ngăn %d", i + 3];
        lbl.textColor = textSub;
        lbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        [slot addSubview:lbl];

        [self.mainContainer addSubview:slot];
        [self.emptySlots addObject:slot];
        [self.emptyLabels addObject:lbl];
    }

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    pan.delegate = self;
    pan.cancelsTouchesInView = NO;
    [self.box addGestureRecognizer:pan];

    [win addSubview:self.box];

    [self updateParamTitles];
    [self layoutMenuAnimated:NO];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(checkMic) name:AVAudioSessionRouteChangeNotification object:nil];
    [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(checkMic) userInfo:nil repeats:YES];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *v = touch.view;
    while (v && v != self.box) {
        if ([v isKindOfClass:[UISlider class]] || [v isKindOfClass:[UISwitch class]]) {
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
}

- (void)onEchoSwitch:(UISwitch *)sender {
    hookGotPointers();
    gEchoEnabled = sender.isOn;
}

- (void)onNganSwitch:(UISwitch *)sender {
    gLongNganEnabled = sender.isOn;
}

- (void)onSelectSliderParam:(UIButton *)sender {
    self.selectedParam = (int)sender.tag;
    if (self.selectedParam == 1) self.bottomSlider.value = gParamEcho;
    if (self.selectedParam == 2) self.bottomSlider.value = gParamGain;
    if (self.selectedParam == 4) self.bottomSlider.value = gParamBass;

    UIColor *borderBasic = [UIColor colorWithRed:0.26 green:0.28 blue:0.33 alpha:1.0];
    UIColor *accentColor = [UIColor colorWithRed:0.35 green:0.55 blue:0.95 alpha:1.0];

    self.btnVang.layer.borderWidth = (self.selectedParam == 1) ? 1.2 : 0.6;
    self.btnVang.layer.borderColor = (self.selectedParam == 1) ? accentColor.CGColor : borderBasic.CGColor;

    self.btnGain.layer.borderWidth = (self.selectedParam == 2) ? 1.2 : 0.6;
    self.btnGain.layer.borderColor = (self.selectedParam == 2) ? accentColor.CGColor : borderBasic.CGColor;

    self.btnBass.layer.borderWidth = (self.selectedParam == 4) ? 1.2 : 0.6;
    self.btnBass.layer.borderColor = (self.selectedParam == 4) ? accentColor.CGColor : borderBasic.CGColor;

    [self updateParamTitles];
}

- (void)onBottomSliderChanged:(UISlider *)sender {
    if (self.selectedParam == 1) gParamEcho = sender.value;
    if (self.selectedParam == 2) gParamGain = sender.value;
    if (self.selectedParam == 4) gParamBass = sender.value;
    [self updateParamTitles];
}

- (void)onToggleExpand {
    self.isExpanded = !self.isExpanded;
    [self layoutMenuAnimated:YES];
}

- (void)onToggleSoundPanel {
    self.isSoundOpen = !self.isSoundOpen;
    UIImageSymbolConfiguration *arrowCfg = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightBold];
    NSString *sym = self.isSoundOpen ? @"chevron.up" : @"chevron.down";
    self.arrowIcon.image = [UIImage systemImageNamed:sym withConfiguration:arrowCfg];
    [self layoutMenuAnimated:YES];
}

- (void)layoutMenuAnimated:(BOOL)animated {
    CGPoint currentCenter = self.box.center;
    void (^applyLayout)(void) = ^{
        if (!self.isExpanded) {
            self.box.bounds = CGRectMake(0, 0, 46, 46);
            self.box.center = currentCenter;
            self.box.layer.cornerRadius = 12.0;
            self.collapsedMicBtn.alpha = 1.0;
            self.mainContainer.alpha = 0.0;
        } else {
            CGFloat y = 86.0;
            if (self.isSoundOpen) {
                self.soundPanel.frame = CGRectMake(8, 86, 180, 162);
                self.soundPanel.alpha = 1.0;
                y = 253.0;
            } else {
                self.soundPanel.frame = CGRectMake(8, 86, 180, 0);
                self.soundPanel.alpha = 0.0;
            }
            for (int i = 0; i < 5; i++) {
                UIView *slot = self.emptySlots[i];
                slot.frame = CGRectMake(8, y, 180, 28);
                y += 33.0;
            }
            CGFloat totalH = y + 3.0;
            self.mainContainer.frame = CGRectMake(0, 0, 196, totalH);
            self.box.bounds = CGRectMake(0, 0, 196, totalH);
            self.box.center = currentCenter;
            self.box.layer.cornerRadius = 14.0;
            self.collapsedMicBtn.alpha = 0.0;
            self.mainContainer.alpha = 1.0;
        }
    };

    if (animated) {
        [UIView animateWithDuration:0.22 animations:applyLayout];
    } else {
        applyLayout();
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
            hookGotPointers();
            [self.box.superview bringSubviewToFront:self.box];
        }
    });
}

- (void)drag:(UIPanGestureRecognizer *)pan {
    CGPoint trans = [pan translationInView:self.box.superview];
    self.box.center = CGPointMake(self.box.center.x + trans.x, self.box.center.y + trans.y);
    [pan setTranslation:CGPointZero inView:self.box.superview];
}

@end

__attribute__((constructor))
static void startMenu() {
    hookGotPointers();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[DiscordMenu shared] setup];
    });
}
