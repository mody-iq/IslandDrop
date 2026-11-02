// IslandDrop - Dynamic Island style droplet notifications (SpringBoard, roothide)
// Ported from rit3zh/expo-dynamic-notifications (timings, springs, neck profile, goo).

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>
#import <dlfcn.h>
#import <IOSurface/IOSurfaceRef.h>

// ---------------------------------------------------------------- constants
static const CGFloat kIslandW = 126.0;
static const CGFloat kIslandH = 37.33;
static const CGFloat kCardMaxW = 396.0;
static const CGFloat kCardH = 74.0;
static const CGFloat kCardMargin = 16.0;
static const CGFloat kDropSize = 52.0;
static const CGFloat kNeckW = 60.0;
static const CGFloat kEdgeMargin = 10.0;
static const CGFloat kDropGrowSpan = 0.7;
static const CGFloat kDropGrowPower = 1.25;
static const CGFloat kDropStretch = 0.38;
static const CGFloat kNeckBreak = 0.82;
static const CGFloat kNeckRise = 1.6;
static const CGFloat kNeckFall = 1.4;
static const CGFloat kTintStart = 0.06;
static const CGFloat kTintEnd = 0.88;
static const CGFloat kContentMinScale = 0.88;
static const CGFloat kShadowDY = 10.0;
static const CGFloat kShadowBlur = 14.0;
static const CFTimeInterval kEnterTintDelay = 0.110;
static const CFTimeInterval kEnterExpandDelay = 0.340;
static const CFTimeInterval kEnterRevealDelay = 0.560;
static const CFTimeInterval kExitCollapseDelay = 0.100;
static const CFTimeInterval kExitDropDelay = 0.280;
static const CGFloat kExitVelocity = 2.0;
static const float kGooColorK = 10.0f;

static char kIDHideKey;
static Class gShortLookClass = Nil;

// ---------------------------------------------------------------- math
static inline CGFloat IDClamp(CGFloat v, CGFloat lo, CGFloat hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static inline CGFloat IDMix(CGFloat t, CGFloat a, CGFloat b) {
    return a + (b - a) * t;
}

static inline CGFloat IDEaseOut(CGFloat p, CGFloat power) {
    CGFloat n = IDClamp(p, 0.0, 1.0);
    return 1.0 - pow(1.0 - n, power);
}

static CGFloat IDNeck(CGFloat progress, CGFloat rise, CGFloat fall) {
    CGFloat t = IDClamp(progress, 0.0, 1.0);
    if (t <= 0.0 || t >= 1.0) return 0.0;
    CGFloat peak = rise / (rise + fall);
    CGFloat normal = pow(peak, rise) * pow(1.0 - peak, fall);
    return (pow(t, rise) * pow(1.0 - t, fall)) / normal;
}

static inline float IDSdRoundRect(float px, float py, float cx, float cy, float hw, float hh, float r) {
    float qx = fabsf(px - cx) - (hw - r);
    float qy = fabsf(py - cy) - (hh - r);
    float ox = fmaxf(qx, 0.0f);
    float oy = fmaxf(qy, 0.0f);
    return sqrtf(ox * ox + oy * oy) + fminf(fmaxf(qx, qy), 0.0f) - r;
}

static inline float IDSmin(float a, float b, float k) {
    float h = fmaxf(k - fabsf(a - b), 0.0f) / k;
    return fminf(a, b) - h * h * k * 0.25f;
}

// ---------------------------------------------------------------- springs
typedef struct {
    CGFloat value;
    CGFloat velocity;
    CGFloat target;
    CGFloat omega;
    CGFloat zeta;
    CFTimeInterval startAt;
} IDSpring;

static void IDSpringInit(IDSpring *s, CGFloat durationMs, CGFloat zeta) {
    s->value = 0.0;
    s->velocity = 0.0;
    s->target = 0.0;
    s->zeta = zeta;
    s->omega = (2.0 * M_PI) / (durationMs / 1000.0);
    s->startAt = 0.0;
}

static void IDSpringRetarget(IDSpring *s, CGFloat durationMs, CGFloat zeta, CGFloat target, CFTimeInterval startAt) {
    s->omega = (2.0 * M_PI) / (durationMs / 1000.0);
    s->zeta = zeta;
    s->target = target;
    s->startAt = startAt;
}

static void IDSpringStep(IDSpring *s, CFTimeInterval now, CFTimeInterval dt) {
    if (now < s->startAt) return;
    int n = (int)ceil(dt * 240.0);
    if (n < 1) n = 1;
    if (n > 12) n = 12;
    CGFloat h = dt / (CGFloat)n;
    for (int i = 0; i < n; i++) {
        CGFloat a = -s->omega * s->omega * (s->value - s->target) - 2.0 * s->zeta * s->omega * s->velocity;
        s->velocity += a * h;
        s->value += s->velocity * h;
    }
}

// ---------------------------------------------------------------- geometry
typedef struct {
    CGFloat width, centerX;
    CGFloat islandW, islandH, islandTop, islandBottom;
    CGFloat cardW, cardH, cardRadius, cardCenterY;
} IDLayout;

typedef struct {
    CGFloat x, y, w, h, r;
    CGFloat neckX, neckY, neckW, neckH;
    CGFloat shadowOpacity, offsetY, widthRatio;
} IDGeo;

static IDGeo IDBuildGeo(CGFloat drop, CGFloat expand, IDLayout L) {
    CGFloat grow = IDEaseOut(IDClamp(drop / kDropGrowSpan, 0.0, 1.0), kDropGrowPower);
    CGFloat neck = IDNeck(drop / kNeckBreak, kNeckRise, kNeckFall);
    CGFloat stretch = 1.0 + kDropStretch * neck;
    CGFloat droplet = kDropSize * grow;

    IDGeo g;
    g.w = MAX(MIN(IDMix(expand, droplet / stretch, L.cardW), L.width - kEdgeMargin * 2.0), 1.0);
    g.h = MAX(IDMix(expand, droplet * stretch, L.cardH), 1.0);
    g.r = MAX(MIN(IDMix(expand, droplet * 0.5, L.cardRadius), MIN(g.w, g.h) / 2.0), 0.0);

    CGFloat originY = L.islandBottom - L.islandH * 0.34;
    CGFloat centerY = IDMix(drop, originY, L.cardCenterY);
    g.x = L.centerX - g.w / 2.0;
    g.y = centerY - g.h / 2.0;

    CGFloat nw = MIN(kNeckW, g.w) * neck;
    CGFloat ny = L.islandBottom - L.islandH * 0.5;
    g.neckW = nw;
    g.neckX = L.centerX - nw / 2.0;
    g.neckY = ny;
    g.neckH = MAX(centerY - ny, 0.0);

    g.shadowOpacity = IDClamp(expand, 0.0, 1.0);
    g.offsetY = centerY - L.cardCenterY;
    g.widthRatio = (L.cardW > 0.0) ? (g.w / L.cardW) : 0.0;
    return g;
}

// ---------------------------------------------------------------- helpers
static NSString *const kIDDomain = @"com.mody.islanddrop";

static id IDPref(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kIDDomain);
    return CFBridgingRelease(v);
}

static BOOL IDPrefBool(NSString *key, BOOL def) {
    id v = IDPref(key);
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    return def;
}

static int IDPrefInt(NSString *key, int def) {
    id v = IDPref(key);
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v intValue];
    return def;
}

static double IDPrefDouble(NSString *key, double def) {
    id v = IDPref(key);
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v doubleValue];
    return def;
}

static BOOL IDEnabled(void) {
    if (!IDPrefBool(@"enabled", YES)) return NO;
    return ![[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Preferences/com.mody.islanddrop.disable"];
}

static BOOL IDIsBannerView(UIView *v) {
    UIResponder *r = v;
    int n = 0;
    while (r && n < 30) {
        NSString *name = NSStringFromClass([r class]);
        if ([name rangeOfString:@"Banner"].location != NSNotFound) return YES;
        r = [r nextResponder];
        n++;
    }
    return NO;
}

static void IDCollectLabels(UIView *root, UIView *ref, NSMutableArray *out) {
    for (UIView *s in root.subviews) {
        if (s.hidden || s.alpha < 0.01) continue;
        if ([s isKindOfClass:[UILabel class]]) {
            UILabel *l = (UILabel *)s;
            NSString *t = l.text.length ? l.text : l.attributedText.string;
            if (t.length) {
                CGRect f = [l convertRect:l.bounds toView:ref];
                [out addObject:@{ @"t": t, @"y": @(f.origin.y), @"w": @(f.size.width) }];
            }
        } else {
            IDCollectLabels(s, ref, out);
        }
    }
}

static BOOL IDContainsLabel(UIView *v) {
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:[UILabel class]]) return YES;
        if (IDContainsLabel(s)) return YES;
    }
    return NO;
}

static UIView *IDFindIcon(UIView *root) {
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    UIView *best = nil;
    CGFloat bestX = 1e9;
    int guardCount = 0;
    while (queue.count > 0 && guardCount < 400) {
        guardCount++;
        UIView *v = queue[0];
        [queue removeObjectAtIndex:0];
        for (UIView *s in v.subviews) {
            if (s.hidden || s.alpha < 0.01) continue;
            if (![s isKindOfClass:[UILabel class]]) {
                CGRect f = [s convertRect:s.bounds toView:root];
                BOOL square = fabs(f.size.width - f.size.height) < 2.0;
                if (square && f.size.width >= 20.0 && f.size.width <= 52.0 && !IDContainsLabel(s)) {
                    CGFloat score = f.origin.x + ((f.size.width >= 30.0) ? 0.0 : 1000.0);
                    if (score < bestX) {
                        bestX = score;
                        best = s;
                    }
                }
                [queue addObject:s];
            }
        }
    }
    return best;
}

static NSString *IDPickRow(NSMutableArray *rest) {
    if (rest.count == 0) return nil;
    CGFloat y0 = [rest[0][@"y"] doubleValue];
    NSDictionary *best = nil;
    NSMutableArray *taken = [NSMutableArray array];
    for (NSDictionary *e in rest) {
        if (fabs([e[@"y"] doubleValue] - y0) <= 8.0) {
            [taken addObject:e];
            if (!best || [e[@"w"] doubleValue] > [best[@"w"] doubleValue]) best = e;
        } else {
            break;
        }
    }
    [rest removeObjectsInArray:taken];
    return best[@"t"];
}

// ---------------------------------------------------------------- accent color from icon (UPDATED)
static UIColor *IDAccentFromImage(UIImage *img) {
    if (!img.CGImage) return nil;
    const int N = 16;
    uint8_t buf[N * N * 4];
    memset(buf, 0, sizeof(buf));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, N, N, 8, N * 4, cs,
                                             (CGBitmapInfo)(kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big));
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, N, N), img.CGImage);
    CGContextRelease(ctx);

    double sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0;
    
    // Pass 1: Look for highly saturated colors (Blue, Green, Red, etc.)
    for (int i = 0; i < N * N; i++) {
        double a = buf[i * 4 + 3] / 255.0;
        if (a < 0.5) continue;
        double r = MIN(1.0, (buf[i * 4] / 255.0) / a);
        double g = MIN(1.0, (buf[i * 4 + 1] / 255.0) / a);
        double b = MIN(1.0, (buf[i * 4 + 2] / 255.0) / a);
        double mx = MAX(r, MAX(g, b));
        double mn = MIN(r, MIN(g, b));
        double sat = (mx > 0.001) ? ((mx - mn) / mx) : 0.0;
        double w = sat * sat * mx;
        sr += r * w; sg += g * w; sb += b * w; sw += w;
    }
    if (sw >= 0.5) return [UIColor colorWithRed:sr / sw green:sg / sw blue:sb / sw alpha:1.0];

    // Pass 2: Fallback for grayscale/white icons (Settings, Messages, etc.)
    sr = 0.0; sg = 0.0; sb = 0.0; sw = 0.0;
    for (int i = 0; i < N * N; i++) {
        double a = buf[i * 4 + 3] / 255.0;
        if (a < 0.5) continue;
        double r = MIN(1.0, (buf[i * 4] / 255.0) / a);
        double g = MIN(1.0, (buf[i * 4 + 1] / 255.0) / a);
        double b = MIN(1.0, (buf[i * 4 + 2] / 255.0) / a);
        
        // Ignore pure white and pure black to find the actual icon graphics
        if (r > 0.9 && g > 0.9 && b > 0.9) continue; 
        if (r < 0.1 && g < 0.1 && b < 0.1) continue;

        sr += r; sg += g; sb += b; sw += 1.0;
    }
    if (sw > 0.5) {
        UIColor *c = [UIColor colorWithRed:sr / sw green:sg / sw blue:sb / sw alpha:1.0];
        CGFloat hue, sat, bright, alpha;
        [c getHue:&hue saturation:&sat brightness:&bright alpha:&alpha];
        if (bright < 0.4) bright = 0.5; // Boost brightness for a nicer glow
        return [UIColor colorWithHue:hue saturation:sat brightness:bright alpha:1.0];
    }
    
    return nil;
}

// ---------------------------------------------------------------- dark / light detection
typedef void (*IDRenderDisplayFn)(uint32_t, CFStringRef, IOSurfaceRef, int, int);

static NSString *const kIDCapturingPath = @"/var/mobile/Library/Preferences/com.mody.islanddrop.capturing";
static NSString *const kIDNoCapturePath = @"/var/mobile/Library/Preferences/com.mody.islanddrop.nocapture";

// returns 1 = dark, 0 = light, -1 = unknown
static int IDDetectDark(UIScreen *screen) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kIDNoCapturePath]) return -1;

    static IDRenderDisplayFn fn = NULL;
    static BOOL resolved = NO;
    if (!resolved) {
        resolved = YES;
        fn = (IDRenderDisplayFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    }
    if (!fn) return -1;

    CGRect nb = screen.nativeBounds;
    CGRect sb = screen.bounds;
    int pw = (int)nb.size.width;
    int ph = (int)nb.size.height;
    if (pw < 100 || ph < 100 || sb.size.width < 100.0 || sb.size.height < 100.0) return -1;

    NSDictionary *props = @{
        (__bridge id)kIOSurfaceWidth: @(pw),
        (__bridge id)kIOSurfaceHeight: @(ph),
        (__bridge id)kIOSurfaceBytesPerElement: @4,
        (__bridge id)kIOSurfacePixelFormat: @(0x42475241)
    };
    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!surf) return -1;

    [fm createFileAtPath:kIDCapturingPath contents:[NSData data] attributes:nil];
    fn(0, CFSTR("LCD"), surf, 0, 0);
    [fm removeItemAtPath:kIDCapturingPath error:nil];

    int result = -1;
    if (IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL) == 0) {
        const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(surf);
        size_t stride = IOSurfaceGetBytesPerRow(surf);
        if (base && stride >= (size_t)pw * 4) {
            const CGFloat sx = (CGFloat)pw / sb.size.width;
            const CGFloat sy = (CGFloat)ph / sb.size.height;
            int hist[256];
            memset(hist, 0, sizeof(hist));
            int count = 0;
            BOOL anyData = NO;
            for (int side = 0; side < 2; side++) {
                CGFloat xStart = (side == 0) ? 8.0 : (sb.size.width - 96.0);
                for (CGFloat x = xStart; x < xStart + 88.0; x += 3.0) {
                    for (CGFloat y = 6.0; y < 26.0; y += 3.0) {
                        int ix = (int)(x * sx);
                        int iy = (int)(y * sy);
                        if (ix < 0 || ix >= pw || iy < 0 || iy >= ph) continue;
                        const uint8_t *px = base + (size_t)iy * stride + (size_t)ix * 4;
                        if (px[0] || px[1] || px[2] || px[3]) anyData = YES;
                        int lum = (int)(0.114 * px[0] + 0.587 * px[1] + 0.299 * px[2]);
                        if (lum < 0) lum = 0;
                        if (lum > 255) lum = 255;
                        hist[lum]++;
                        count++;
                    }
                }
            }
            if (anyData && count > 20) {
                int acc = 0;
                int median = 0;
                for (int i = 0; i < 256; i++) {
                    acc += hist[i];
                    if (acc * 2 >= count) { median = i; break; }
                }
                result = (median < 115) ? 1 : 0;
            }
        }
        IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    }
    CFRelease(surf);
    return result;
}

// ---------------------------------------------------------------- overlay window
@interface IDOverlayWindow : UIWindow
@end

@implementation IDOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeFirstResponder { return NO; }
@end

// ---------------------------------------------------------------- session
static uint8_t *gBuf = NULL;
static size_t gBufCap = 0;
static CGColorSpaceRef gCS = NULL;

@interface IDSession : NSObject {
    IDLayout _L;
    IDSpring _drop, _expand, _reveal, _tint;
    CGFloat _scale;
    CFTimeInterval _startTime, _lastTime, _exitTime;
    BOOL _exiting, _finished, _gotTitle, _dark;
    float _cardR, _cardG, _cardB;
    double _tm;
    float _gooK;
    BOOL _glowOn;
    UIColor *_accent;
    CAShapeLayer *_glow;
    CGFloat _topSeen, _origAlpha;
    CADisplayLink *_link;
    IDOverlayWindow *_window;
    UIView *_root;
    CAShapeLayer *_shadow;
    CALayer *_goo;
    UIView *_content;
    UIView *_iconHolder;
    UIImageView *_iconView;
    UILabel *_titleLabel;
    UILabel *_bodyLabel;
    CAShapeLayer *_contentMask;
}
@property (nonatomic, weak) UIView *source;
- (instancetype)initWithSource:(UIView *)src;
- (void)beginExit;
- (void)finish;
@end

static IDSession *gSession = nil;

@implementation IDSession

- (instancetype)initWithSource:(UIView *)src {
    self = [super init];
    if (!self) return nil;

    _source = src;
    UIWindow *bw = src.window;
    UIScreen *screen = bw.screen ?: [UIScreen mainScreen];
    CGRect sb = screen.bounds;
    _scale = (screen.scale >= 2.0) ? 2.0 : 1.0;

    CGFloat inset = bw.safeAreaInsets.top;
    CGFloat islandBottom = (inset >= 51.0) ? (11.0 + kIslandH) : 30.0;

    _L.width = sb.size.width;
    _L.centerX = sb.size.width / 2.0;
    _L.islandW = kIslandW;
    _L.islandH = kIslandH;
    _L.islandBottom = islandBottom;
    _L.islandTop = islandBottom - kIslandH;
    _L.cardW = MIN(sb.size.width - kCardMargin * 2.0, kCardMaxW);
    _L.cardH = kCardH;
    _L.cardRadius = kCardH / 2.0;
    _topSeen = islandBottom + 16.0;
    _L.cardCenterY = _topSeen + kCardH / 2.0;

    // user settings (read fresh for every notification)
    int speedMode = IDPrefInt(@"speed", 1);
    _tm = (speedMode == 0) ? 1.35 : ((speedMode == 2) ? 0.72 : 1.0);
    double goo = IDPrefDouble(@"goo", 0.62);
    if (goo < 0.0) goo = 0.0;
    if (goo > 1.0) goo = 1.0;
    _gooK = (float)(8.0 + 16.0 * goo);
    _glowOn = IDPrefBool(@"glow", NO);
    int hapticMode = IDPrefInt(@"haptic", 1);
    int cardMode = IDPrefInt(@"cardMode", 0);

    IDSpringInit(&_drop, 1150.0 * _tm, 0.82);
    IDSpringInit(&_expand, 1000.0 * _tm, 0.8);
    IDSpringInit(&_reveal, 700.0 * _tm, 1.0);
    IDSpringInit(&_tint, 700.0 * _tm, 1.0);
    _startTime = CACurrentMediaTime();
    _drop.target = 1.0;
    _drop.startAt = _startTime;
    _tint.target = 1.0;
    _tint.startAt = _startTime + kEnterTintDelay * _tm;
    _expand.target = 1.0;
    _expand.startAt = _startTime + kEnterExpandDelay * _tm;
    _reveal.target = 1.0;
    _reveal.startAt = _startTime + kEnterRevealDelay * _tm;

    // dark / light card (auto = measure the screen before our overlay is visible)
    int dk = 0;
    if (cardMode == 1) {
        dk = 0;
    } else if (cardMode == 2) {
        dk = 1;
    } else {
        dk = IDDetectDark(screen);
    }
    _dark = (dk == 1);
    _cardR = _dark ? (28.0f / 255.0f) : 1.0f;
    _cardG = _dark ? (28.0f / 255.0f) : 1.0f;
    _cardB = _dark ? (30.0f / 255.0f) : 1.0f;

    // overlay window
    UIWindowScene *scene = bw.windowScene;
    if (scene) {
        _window = [[IDOverlayWindow alloc] initWithWindowScene:scene];
    } else {
        _window = [[IDOverlayWindow alloc] initWithFrame:sb];
    }
    _window.frame = sb;
    _window.windowLevel = 100000.0;
    _window.backgroundColor = [UIColor clearColor];
    _window.userInteractionEnabled = NO;
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = NO;
    _window.rootViewController = vc;
    _root = vc.view;

    // layers
    _shadow = [CAShapeLayer layer];
    _shadow.frame = CGRectMake(0, 0, sb.size.width, sb.size.height);
    _shadow.fillColor = [UIColor colorWithWhite:1.0 alpha:0.01].CGColor;
    _shadow.shadowColor = [UIColor colorWithRed:16.0 / 255.0 green:19.0 / 255.0 blue:28.0 / 255.0 alpha:0.20].CGColor;
    _shadow.shadowOffset = CGSizeMake(0, kShadowDY);
    _shadow.shadowRadius = kShadowBlur / 2.0;
    _shadow.shadowOpacity = 0.0;
    _shadow.lineWidth = 1.0;
    _shadow.strokeColor = NULL;
    [_root.layer addSublayer:_shadow];

    _glow = [CAShapeLayer layer];
    _glow.frame = CGRectMake(0, 0, sb.size.width, sb.size.height);
    _glow.fillColor = NULL;
    _glow.strokeColor = NULL;
    _glow.lineWidth = 2.0;
    _glow.shadowOffset = CGSizeZero;
    _glow.shadowRadius = 9.0;
    _glow.shadowOpacity = 0.0;
    [_root.layer addSublayer:_glow];

    _goo = [CALayer layer];
    _goo.contentsScale = _scale;
    _goo.contentsGravity = kCAGravityResize;
    [_root.layer addSublayer:_goo];

    // content
    _content = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _L.cardW, _L.cardH)];
    _content.alpha = 0.0;
    _contentMask = [CAShapeLayer layer];
    _contentMask.fillColor = [UIColor blackColor].CGColor;
    _content.layer.mask = _contentMask;

    _iconHolder = [[UIView alloc] initWithFrame:CGRectMake(13.0, (_L.cardH - 46.0) / 2.0, 46.0, 46.0)];
    _iconHolder.backgroundColor = [UIColor clearColor];
    _iconHolder.layer.masksToBounds = NO;
    [_content addSubview:_iconHolder];
    _iconView = [[UIImageView alloc] initWithFrame:_iconHolder.bounds];
    _iconView.contentMode = UIViewContentModeScaleToFill;
    [_iconHolder addSubview:_iconView];

    CGFloat textX = 13.0 + 46.0 + 12.0;
    CGFloat textW = _L.cardW - textX - 20.0;
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(textX, 17.0, textW, 21.0)];
    _titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
    _titleLabel.textColor = _dark ? [UIColor whiteColor] : [UIColor colorWithRed:17.0 / 255.0 green:17.0 / 255.0 blue:20.0 / 255.0 alpha:1.0];
    _titleLabel.textAlignment = NSTextAlignmentNatural;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.numberOfLines = 1;
    [_content addSubview:_titleLabel];

    _bodyLabel = [[UILabel alloc] initWithFrame:CGRectMake(textX, 39.0, textW, 18.0)];
    _bodyLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    _bodyLabel.textColor = _dark ? [UIColor colorWithRed:174.0 / 255.0 green:174.0 / 255.0 blue:178.0 / 255.0 alpha:1.0] : [UIColor colorWithRed:119.0 / 255.0 green:120.0 / 255.0 blue:125.0 / 255.0 alpha:1.0];
    _bodyLabel.textAlignment = NSTextAlignmentNatural;
    _bodyLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _bodyLabel.numberOfLines = 1;
    [_content addSubview:_bodyLabel];

    [_root addSubview:_content];

    // grab content BEFORE hiding the system banner
    [self captureContent];

    // hide system banner (stays tappable: alpha >= 0.01)
    _origAlpha = src.alpha;
    objc_setAssociatedObject(src, &kIDHideKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [src setAlpha:_origAlpha];

    _window.hidden = NO;

    if (hapticMode > 0) {
        UIImpactFeedbackStyle style = (hapticMode == 2) ? UIImpactFeedbackStyleMedium : UIImpactFeedbackStyleLight;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kEnterExpandDelay * _tm * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            static UIImpactFeedbackGenerator *gHaptic = nil;
            gHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
            [gHaptic impactOccurred];
        });
    }

    __weak IDSession *ws = self;
    double delays[3] = { 0.12, 0.40, 0.90 };
    for (int i = 0; i < 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ws captureContent];
        });
    }

    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    return self;
}

- (void)captureContent {
    UIView *src = self.source;
    if (!src || _finished) return;

    if (!_gotTitle) {
        NSMutableArray *entries = [NSMutableArray array];
        IDCollectLabels(src, src, entries);
        NSArray *sorted = [entries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"y"] compare:b[@"y"]];
        }];
        NSMutableArray *rest = [sorted mutableCopy];
        NSString *title = IDPickRow(rest);
        NSString *body = IDPickRow(rest);
        if (title.length) {
            _titleLabel.text = title;
            _bodyLabel.text = body ?: @"";
            if (!body.length) {
                _titleLabel.frame = CGRectMake(_titleLabel.frame.origin.x, (_L.cardH - 21.0) / 2.0, _titleLabel.frame.size.width, 21.0);
            } else {
                _titleLabel.frame = CGRectMake(_titleLabel.frame.origin.x, 17.0, _titleLabel.frame.size.width, 21.0);
            }
            _gotTitle = YES;
        }
    }

    UIView *icon = IDFindIcon(src);
    if (icon && icon.bounds.size.width > 1.0 && icon.bounds.size.height > 1.0) {
        CGSize sz = icon.bounds.size;
        CGFloat p = sz.width * 0.15;
        CGSize canvas = CGSizeMake(sz.width + p * 2.0, sz.height + p * 2.0);
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
        fmt.opaque = NO;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvas format:fmt];
        UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rc) {
            CGContextTranslateCTM(rc.CGContext, p, p);
            [icon.layer renderInContext:rc.CGContext];
        }];
        if (img) {
            CGFloat k = 46.0 / sz.width;
            CGFloat pp = p * k;
            _iconView.frame = CGRectMake(-pp, -pp, 46.0 + pp * 2.0, 46.0 * (sz.height / sz.width) + pp * 2.0);
            _iconView.image = img;
            // Extract the color whenever the icon is found
            if (_glowOn) _accent = IDAccentFromImage(img);
        }
    }
}

- (void)beginExit {
    if (_exiting || _finished) return;
    _exiting = YES;
    CFTimeInterval now = CACurrentMediaTime();
    _exitTime = now;
    IDSpringRetarget(&_reveal, 360.0 * _tm, 1.0, 0.0, now);
    IDSpringRetarget(&_expand, 660.0 * _tm, 0.92, 0.0, now + kExitCollapseDelay * _tm);
    _expand.velocity = kExitVelocity;
    IDSpringRetarget(&_tint, 1150.0 * _tm, 0.9, 0.0, now + kExitDropDelay * _tm);
    IDSpringRetarget(&_drop, 1150.0 * _tm, 0.9, 0.0, now + kExitDropDelay * _tm);
}

- (void)finish {
    if (_finished) return;
    _finished = YES;
    [_link invalidate];
    _link = nil;
    _window.hidden = YES;
    _window.rootViewController = nil;
    _window = nil;
    UIView *src = self.source;
    if (src) {
        objc_setAssociatedObject(src, &kIDHideKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        src.alpha = (_origAlpha < 0.9) ? 1.0 : _origAlpha;
    }
    if (gSession == self) gSession = nil;
}

- (void)tick:(CADisplayLink *)link {
    if (_finished) return;
    CFTimeInterval now = link.timestamp;
    CFTimeInterval dt = (_lastTime > 0.0) ? MIN(now - _lastTime, 1.0 / 20.0) : (1.0 / 60.0);
    _lastTime = now;

    UIView *src = self.source;
    if (!_exiting) {
        if (!src || !src.window || src.window.hidden) {
            [self beginExit];
        } else {
            CGRect f = [src convertRect:src.bounds toCoordinateSpace:src.window.screen.coordinateSpace];
            if (f.origin.y > _topSeen && f.origin.y < 160.0) _topSeen = f.origin.y;
            if ((now - _startTime) > 0.9 && f.origin.y < _topSeen - 24.0) [self beginExit];
        }
        if ((now - _startTime) > 90.0) {
            [self finish];
            return;
        }
    } else if ((now - _exitTime) > 4.0) {
        [self finish];
        return;
    }

    _L.cardCenterY = _topSeen + _L.cardH / 2.0;

    IDSpringStep(&_drop, now, dt);
    IDSpringStep(&_tint, now, dt);
    IDSpringStep(&_expand, now, dt);
    IDSpringStep(&_reveal, now, dt);

    IDGeo g = IDBuildGeo(_drop.value, _expand.value, _L);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    [self renderGoo:g];

    UIBezierPath *cardPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(g.x, g.y, g.w, g.h) cornerRadius:g.r];
    _shadow.path = cardPath.CGPath;
    _shadow.shadowPath = cardPath.CGPath;
    _shadow.shadowOpacity = (float)g.shadowOpacity;
    
    // UPDATED GLOW LOGIC HERE
    BOOL glowing = (_glowOn && _accent != nil);
    if (glowing) {
        _glow.path = cardPath.CGPath;
        _glow.shadowPath = cardPath.CGPath;
        _glow.strokeColor = [_accent colorWithAlphaComponent:0.9 * g.shadowOpacity].CGColor;
        _glow.shadowColor = _accent.CGColor;
        _glow.shadowOpacity = (float)(0.65 * g.shadowOpacity);
        
        // Make the main shadow (drop shadow) use the app's accent color instead of black!
        _shadow.shadowColor = _accent.CGColor;
        _shadow.shadowOpacity = (float)(0.5 * g.shadowOpacity); // Slightly lower opacity for the main shadow
        
        _shadow.strokeColor = NULL;
    } else {
        // Default dark shadow
        _glow.shadowOpacity = 0.0;
        _glow.strokeColor = NULL;
        
        _shadow.shadowColor = [UIColor colorWithRed:16.0 / 255.0 green:19.0 / 255.0 blue:28.0 / 255.0 alpha:0.20].CGColor;
        _shadow.shadowOpacity = (float)g.shadowOpacity;
        
        if (_dark) {
            _shadow.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.16 * g.shadowOpacity].CGColor;
        } else {
            _shadow.strokeColor = NULL;
        }
    }

    CGFloat progress = IDClamp(_reveal.value, 0.0, 1.0);
    CGFloat overshoot = IDClamp(g.widthRatio - 1.0, 0.0, 0.2);
    CGFloat sc = IDMix(progress, kContentMinScale, 1.0) + overshoot * progress;
    _content.alpha = progress;
    _content.center = CGPointMake(_L.centerX, g.y + g.h / 2.0);
    _content.transform = CGAffineTransformMakeScale(sc, sc);
    CGRect mr = CGRectMake((_L.cardW - g.w) / 2.0, (_L.cardH - g.h) / 2.0, g.w, g.h);
    _contentMask.frame = _content.bounds;
    _contentMask.path = [UIBezierPath bezierPathWithRoundedRect:mr cornerRadius:g.r].CGPath;

    [CATransaction commit];

    if (_exiting && now >= _drop.startAt && fabs(_drop.value) < 0.004 && fabs(_drop.velocity) < 0.02 && fabs(_expand.value) < 0.01) {
        [self finish];
    }
}

- (void)renderGoo:(IDGeo)g {
    const float S = (float)_scale;
    const float invS = 1.0f / S;
    const float gk = _gooK;
    const float pad = gk + 3.0f;

    CGFloat leftEdge = MIN(_L.centerX - _L.islandW / 2.0, g.x);
    CGFloat rightEdge = MAX(_L.centerX + _L.islandW / 2.0, g.x + g.w);
    CGFloat minX = MAX(0.0, floor(leftEdge - pad));
    CGFloat maxX = MIN(_L.width, ceil(rightEdge + pad));
    CGFloat minY = MAX(0.0, floor(_L.islandTop - pad));
    CGFloat maxY = ceil(g.y + g.h + pad);

    int pw = (int)((maxX - minX) * S);
    int ph = (int)((maxY - minY) * S);
    if (pw < 2 || ph < 2 || pw > 4000 || ph > 4000) return;

    size_t need = (size_t)pw * (size_t)ph * 4;
    if (need > gBufCap) {
        uint8_t *nb = (uint8_t *)realloc(gBuf, need);
        if (!nb) return;
        gBuf = nb;
        gBufCap = need;
    }
    memset(gBuf, 0, need);

    const float icx = (float)_L.centerX;
    const float icy = (float)(_L.islandTop + _L.islandH / 2.0);
    const float ihw = (float)(_L.islandW / 2.0);
    const float ihh = (float)(_L.islandH / 2.0);
    const float ir = ihh;

    const float ccx = (float)(g.x + g.w / 2.0);
    const float ccy = (float)(g.y + g.h / 2.0);
    const float chw = (float)(g.w / 2.0);
    const float chh = (float)(g.h / 2.0);
    const float cr = (float)g.r;

    const BOOL hasNeck = (g.neckW > 0.5 && g.neckH > 0.5);
    const float ncy = (float)(g.neckY + g.neckH / 2.0);
    const float nhw = (float)(g.neckW / 2.0);
    const float nhh = (float)(g.neckH / 2.0);
    const float nr = (float)MIN(g.neckW / 2.0, g.neckH / 2.0);

    const float tintT = (float)IDClamp((_tint.value - kTintStart) / (kTintEnd - kTintStart), 0.0, 1.0);
    const float invK2 = 1.0f / (2.0f * kGooColorK);
    const float cardR = _cardR;
    const float cardG = _cardG;
    const float cardB = _cardB;
    const float x0 = (float)minX;
    const float y0 = (float)minY;

    for (int py = 0; py < ph; py++) {
        const float y = y0 + ((float)py + 0.5f) * invS;
        uint8_t *row = gBuf + (size_t)py * (size_t)pw * 4;
        for (int px = 0; px < pw; px++) {
            const float x = x0 + ((float)px + 0.5f) * invS;
            const float dI = IDSdRoundRect(x, y, icx, icy, ihw, ihh, ir);
            float dB = dI;
            if (hasNeck) {
                const float dN = IDSdRoundRect(x, y, icx, ncy, nhw, nhh, nr);
                dB = IDSmin(dI, dN, gk);
            }
            const float dC = IDSdRoundRect(x, y, ccx, ccy, chw, chh, cr);
            const float d = IDSmin(dB, dC, gk);
            float cov = 0.5f - d * S;
            if (cov <= 0.0f) continue;
            if (cov > 1.0f) cov = 1.0f;
            float t = 0.5f + (dB - dC) * invK2;
            if (t < 0.0f) t = 0.0f;
            if (t > 1.0f) t = 1.0f;
            const float w = t * tintT * cov * 255.0f;
            uint8_t *p = row + (size_t)px * 4;
            p[0] = (uint8_t)(w * cardR + 0.5f);
            p[1] = (uint8_t)(w * cardG + 0.5f);
            p[2] = (uint8_t)(w * cardB + 0.5f);
            p[3] = (uint8_t)(cov * 255.0f + 0.5f);
        }
    }

    if (!gCS) gCS = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(gBuf, (size_t)pw, (size_t)ph, 8, (size_t)pw * 4, gCS,
                                             (CGBitmapInfo)(kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big));
    if (!ctx) return;
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!img) return;

    _goo.frame = CGRectMake(minX, minY, (CGFloat)pw / _scale, (CGFloat)ph / _scale);
    _goo.contents = (__bridge id)img;
    CGImageRelease(img);
}

@end

// ---------------------------------------------------------------- hook glue
static void IDHandleAppear(UIView *v) {
    if (!v || !v.window) return;
    if (!IDEnabled()) return;
    if (gSession && gSession.source == v) return;
    if (!IDIsBannerView(v)) return;
    UIScreen *screen = v.window.screen ?: [UIScreen mainScreen];
    CGRect sb = screen.bounds;
    if (sb.size.width > sb.size.height) return;
    if (gSession) {
        [gSession finish];
        gSession = nil;
    }
    gSession = [[IDSession alloc] initWithSource:v];
}

static void IDHandleDisappear(UIView *v) {
    __weak UIView *wv = v;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        IDSession *cur = gSession;
        if (!cur) return;
        UIView *s = wv;
        if (cur.source == s && (!s || !s.window)) {
            [cur beginExit];
        }
    });
}

@interface NCNotificationShortLookView : UIView
@end

%hook NCNotificationShortLookView

- (void)didMoveToWindow {
    %orig;
    if (!gShortLookClass || ![self isKindOfClass:gShortLookClass]) return;
    UIView *v = (UIView *)self;
    if (v.window) {
        __weak UIView *wv = v;
        dispatch_async(dispatch_get_main_queue(), ^{
            IDHandleAppear(wv);
        });
    } else {
        IDHandleDisappear(v);
    }
}

- (void)setAlpha:(CGFloat)alpha {
    if (gShortLookClass && [self isKindOfClass:gShortLookClass] && objc_getAssociatedObject(self, &kIDHideKey)) {
        %orig(0.02);
        return;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.apple.springboard"]) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:kIDCapturingPath]) {
            [fm createFileAtPath:kIDNoCapturePath contents:[NSData data] attributes:nil];
            [fm removeItemAtPath:kIDCapturingPath error:nil];
        }
        gShortLookClass = (Class)objc_getClass("NCNotificationShortLookView");
        if (!gShortLookClass) return;
        %init;
    }
}
