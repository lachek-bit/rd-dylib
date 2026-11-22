//
//  RDTool.m
//  工具注册表 —— 把能力包装成「名字 + 参数 + 执行体」，像 MCP 的 tools 一样可枚举、可调用
//
//  内置工具覆盖：看（界面/日志/信息）、点（坐标/文字/开关/滑动/输入）、
//  跑（JS/hook/反射）、系统（震动/剪贴板/URL/重启）。
//  自定义工具用 JS 写，落盘到 tools.json，重启后还在。
//

#import "RD.h"
#import <objc/runtime.h>
#import <AudioToolbox/AudioToolbox.h>
#import <pthread.h>
#import <stdlib.h>

@interface UIView (RDFindFirstResponder)
- (UIView *)findFirstResponder;
@end

#pragma mark - 工具对象

@interface RDTool : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *desc;
@property (nonatomic, copy) NSString *group;
@property (nonatomic, strong) NSArray *params;
@property (nonatomic, assign) BOOL builtin;
@property (nonatomic, copy) RDToolHandler handler;
@property (nonatomic, copy) NSString *jsCode;
@end

@implementation RDTool
@end

static NSMutableDictionary<NSString *, RDTool *> *gTools = nil;
static pthread_mutex_t gToolLock = PTHREAD_MUTEX_INITIALIZER;

#pragma mark - 参数取值

static NSString *RDArgStr(NSDictionary *a, NSString *k, NSString *dflt) {
    id v = a[k];
    if (!v || v == [NSNull null]) return dflt;
    if ([v isKindOfClass:[NSString class]]) return v;
    return [v description];
}

static double RDArgNum(NSDictionary *a, NSString *k, double dflt) {
    id v = a[k];
    if (!v || v == [NSNull null]) return dflt;
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return dflt;
}

static NSInteger RDArgInt(NSDictionary *a, NSString *k, NSInteger dflt) {
    id v = a[k];
    if (!v || v == [NSNull null]) return dflt;
    if ([v isKindOfClass:[NSNumber class]]) return [v integerValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v integerValue];
    return dflt;
}

static BOOL RDArgBool(NSDictionary *a, NSString *k, BOOL dflt) {
    id v = a[k];
    if (!v || v == [NSNull null]) return dflt;
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v lowercaseString];
        return [s isEqualToString:@"1"] || [s isEqualToString:@"true"] || [s isEqualToString:@"yes"];
    }
    return dflt;
}

static NSDictionary *P(NSString *name, NSString *type, BOOL required, NSString *desc) {
    return @{@"name": name, @"type": type, @"required": @(required), @"desc": desc ?: @""};
}

#pragma mark - 注册

void RDRegisterTool(NSString *name, NSString *title, NSString *desc,
                    NSArray<NSDictionary *> *params, NSString *group,
                    RDToolHandler handler) {
    if (!name.length || !handler) return;
    RDTool *t = [RDTool new];
    t.name = name;
    t.title = title ?: name;
    t.desc = desc ?: @"";
    t.group = group ?: @"其他";
    t.params = params ?: @[];
    t.builtin = YES;
    t.handler = handler;

    pthread_mutex_lock(&gToolLock);
    if (!gTools) gTools = [NSMutableDictionary dictionary];
    gTools[name] = t;
    pthread_mutex_unlock(&gToolLock);
}

BOOL RDToolIsBuiltin(NSString *name) {
    pthread_mutex_lock(&gToolLock);
    RDTool *t = gTools[name];
    BOOL b = t.builtin;
    pthread_mutex_unlock(&gToolLock);
    return b;
}

NSArray *RDToolList(void) {
    NSMutableArray *out = [NSMutableArray array];
    pthread_mutex_lock(&gToolLock);
    NSArray *keys = [[gTools allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *k in keys) {
        RDTool *t = gTools[k];
        [out addObject:@{
            @"name": t.name,
            @"title": t.title,
            @"desc": t.desc,
            @"group": t.group,
            @"params": t.params,
            @"builtin": @(t.builtin)
        }];
    }
    pthread_mutex_unlock(&gToolLock);
    return out;
}

id RDCallTool(NSString *name, NSDictionary *args, NSString **err) {
    pthread_mutex_lock(&gToolLock);
    RDTool *t = gTools[name];
    pthread_mutex_unlock(&gToolLock);

    if (!t) {
        if (err) *err = [NSString stringWithFormat:@"没有这个工具: %@", name];
        return nil;
    }

    if (t.handler) {
        @try {
            return t.handler(args ?: @{});
        } @catch (NSException *e) {
            if (err) *err = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
            return nil;
        }
    }

    if (t.jsCode.length) {
        NSError *je = nil;
        NSData *jd = [NSJSONSerialization dataWithJSONObject:(args ?: @{}) options:0 error:&je];
        NSString *json = jd ? [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding] : @"{}";
        NSString *code = [NSString stringWithFormat:
                          @"(function(){\nvar args = %@;\n%@\n})()", json, t.jsCode];
        NSString *r = RDEvalSource(code);
        if ([r hasPrefix:@"ERROR: "]) {
            if (err) *err = [r substringFromIndex:7];
            return nil;
        }
        return r;
    }

    if (err) *err = @"工具没有执行体";
    return nil;
}

BOOL RDDeleteTool(NSString *name) {
    pthread_mutex_lock(&gToolLock);
    RDTool *t = gTools[name];
    BOOL can = (t && !t.builtin);
    if (can) [gTools removeObjectForKey:name];
    pthread_mutex_unlock(&gToolLock);
    if (can) RDToolPersist();
    return can;
}

#pragma mark - 自定义 JS 工具

static NSString *RDToolsPath(void) {
    return [RDDataDir() stringByAppendingPathComponent:@"tools.json"];
}

BOOL RDDefineJSTool(NSDictionary *def, NSString **err) {
    NSString *name = def[@"name"];
    NSString *code = def[@"code"];
    if (!name.length || !code.length) {
        if (err) *err = @"需要 name 和 code";
        return NO;
    }
    if (![name isKindOfClass:[NSString class]] || [name containsString:@" "]) {
        if (err) *err = @"name 不能带空格";
        return NO;
    }
    if (RDToolIsBuiltin(name)) {
        if (err) *err = [NSString stringWithFormat:@"%@ 是内置工具，换个名字", name];
        return NO;
    }

    RDTool *t = [RDTool new];
    t.name = name;
    t.title = def[@"title"] ?: name;
    t.desc = def[@"desc"] ?: @"";
    t.group = def[@"group"] ?: @"自定义";
    t.params = [def[@"params"] isKindOfClass:[NSArray class]] ? def[@"params"] : @[];
    t.builtin = NO;
    t.jsCode = code;

    pthread_mutex_lock(&gToolLock);
    if (!gTools) gTools = [NSMutableDictionary dictionary];
    gTools[name] = t;
    pthread_mutex_unlock(&gToolLock);

    RDToolPersist();
    return YES;
}

BOOL RDToolPersist(void) {
    NSMutableArray *arr = [NSMutableArray array];
    pthread_mutex_lock(&gToolLock);
    for (NSString *k in gTools) {
        RDTool *t = gTools[k];
        if (t.builtin) continue;
        [arr addObject:@{
            @"name": t.name,
            @"title": t.title ?: t.name,
            @"desc": t.desc ?: @"",
            @"group": t.group ?: @"自定义",
            @"params": t.params ?: @[],
            @"code": t.jsCode ?: @""
        }];
    }
    pthread_mutex_unlock(&gToolLock);

    NSData *d = [NSJSONSerialization dataWithJSONObject:arr options:NSJSONWritingPrettyPrinted error:nil];
    if (!d) return NO;
    return [d writeToFile:RDToolsPath() atomically:YES];
}

void RDToolLoadPersisted(void) {
    NSData *d = [NSData dataWithContentsOfFile:RDToolsPath()];
    if (!d.length) return;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![arr isKindOfClass:[NSArray class]]) return;

    NSUInteger n = 0;
    for (NSDictionary *item in arr) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *e = nil;
        if (RDDefineJSTool(item, &e)) n++;
    }
    if (n) RDLogAppend([NSString stringWithFormat:@"[TOOL] 恢复 %lu 个自定义工具", (unsigned long)n]);
}

#pragma mark - 内置工具

static void RDToolRegisterUIGroup(void) {
    // ---------- 看 ----------
    RDRegisterTool(@"ui.tree", @"界面元素表",
        @"列出当前界面上所有可点击/可识别的元素：序号、类型、文字、中心坐标",
        @[], @"看", ^id(NSDictionary *a) {
            NSArray *tree = RDInteractiveTree();
            return @{@"count": @(tree.count), @"items": tree};
        });

    RDRegisterTool(@"ui.dump", @"界面层级",
        @"完整视图树（含 frame / tag / hidden）",
        @[], @"看", ^id(NSDictionary *a) {
            return RDUIDump() ?: @"";
        });

    RDRegisterTool(@"ui.vc", @"控制器栈",
        @"当前控制器链",
        @[], @"看", ^id(NSDictionary *a) {
            return RDUIDumpVC() ?: @"";
        });

    RDRegisterTool(@"ui.shot", @"截图",
        @"当前屏幕截图，返回 base64 JPEG",
        @[P(@"q", @"number", NO, @"画质 0-1，默认 0.6")], @"看", ^id(NSDictionary *a) {
            double q = RDArgNum(a, @"q", 0.6);
            NSData *d = RDScreenshotJPEG(MAX(0.1, MIN(1.0, q)));
            if (!d) return @"没有窗口";
            return [NSString stringWithFormat:@"data:image/jpeg;base64,%@",
                    [d base64EncodedStringWithOptions:0]];
        });

    RDRegisterTool(@"screen.size", @"屏幕尺寸",
        @"屏幕点尺寸、缩放、安全区",
        @[], @"看", ^id(NSDictionary *a) {
            __block NSDictionary *r = nil;
            RDRunOnMain(^id{
                UIScreen *s = [UIScreen mainScreen];
                UIWindow *w = RDKeyWindow();
                r = @{
                    @"width": @(s.bounds.size.width),
                    @"height": @(s.bounds.size.height),
                    @"scale": @(s.scale),
                    @"window": w ? NSStringFromCGRect(w.frame) : @"-",
                    @"top": @(w.safeAreaInsets.top),
                    @"bottom": @(w.safeAreaInsets.bottom)
                };
                return (id)nil;
            });
            return r ?: @{};
        });

    // ---------- 点 ----------
    RDRegisterTool(@"ui.tap", @"点击坐标",
        @"在屏幕坐标 (x,y) 点一下，走真实触摸注入",
        @[P(@"x", @"number", YES, @"屏幕 x"),
          P(@"y", @"number", YES, @"屏幕 y")], @"点", ^id(NSDictionary *a) {
            CGPoint p = CGPointMake(RDArgNum(a, @"x", 0), RDArgNum(a, @"y", 0));
            BOOL ok = RDTapPoint(p);
            if (!ok) return @{@"ok": @NO, @"error": @"触摸注入不可用，改用 ui.tapText"};
            RDLogAppend([NSString stringWithFormat:@"[TAP] (%.0f,%.0f)", p.x, p.y]);
            return @{@"ok": @YES, @"x": @(p.x), @"y": @(p.y)};
        });

    RDRegisterTool(@"ui.tapRatio", @"按比例点击",
        @"用 0-1 的相对坐标点击，适配不同机型",
        @[P(@"rx", @"number", YES, @"0-1"),
          P(@"ry", @"number", YES, @"0-1")], @"点", ^id(NSDictionary *a) {
            __block CGSize sz = CGSizeZero;
            RDRunOnMain(^id{ sz = [UIScreen mainScreen].bounds.size; return (id)nil; });
            CGPoint p = CGPointMake(sz.width * RDArgNum(a, @"rx", 0.5),
                                    sz.height * RDArgNum(a, @"ry", 0.5));
            return @{@"ok": @(RDTapPoint(p)), @"x": @(p.x), @"y": @(p.y)};
        });

    RDRegisterTool(@"ui.tapText", @"按文字点击",
        @"找到文字包含指定内容的元素并点击（按钮/标签/列表项都行）",
        @[P(@"text", @"string", YES, @"要匹配的文字"),
          P(@"index", @"number", NO, @"第几个匹配，默认 0")], @"点", ^id(NSDictionary *a) {
            NSString *text = RDArgStr(a, @"text", nil);
            if (!text.length) return @{@"ok": @NO, @"error": @"缺少 text"};
            UIView *v = RDFindViewByText(text, RDArgInt(a, @"index", 0));
            if (!v) return @{@"ok": @NO, @"error": @"没找到"};
            BOOL ok = RDTapView(v);
            RDLogAppend([NSString stringWithFormat:@"[TAP-TEXT] \"%@\" -> %@ ok=%d",
                         text, NSStringFromClass([v class]), ok]);
            return @{@"ok": @(ok), @"cls": NSStringFromClass([v class]) ?: @""};
        });

    RDRegisterTool(@"ui.tapId", @"按 id 点击",
        @"按 accessibilityIdentifier 精确定位并点击",
        @[P(@"id", @"string", YES, @"identifier"),
          P(@"index", @"number", NO, @"第几个，默认 0")], @"点", ^id(NSDictionary *a) {
            NSString *ident = RDArgStr(a, @"id", nil);
            UIView *v = ident.length ? RDFindViewByIdent(ident, RDArgInt(a, @"index", 0)) : nil;
            if (!v) return @{@"ok": @NO, @"error": @"没找到"};
            return @{@"ok": @(RDTapView(v)), @"cls": NSStringFromClass([v class]) ?: @""};
        });

    RDRegisterTool(@"ui.swipe", @"滑动",
        @"从一点滑到另一点，用于翻页/返回",
        @[P(@"x1", @"number", YES, @"起点 x"), P(@"y1", @"number", YES, @"起点 y"),
          P(@"x2", @"number", YES, @"终点 x"), P(@"y2", @"number", YES, @"终点 y"),
          P(@"duration", @"number", NO, @"秒，默认 0.25")], @"点", ^id(NSDictionary *a) {
            CGPoint from = CGPointMake(RDArgNum(a, @"x1", 0), RDArgNum(a, @"y1", 0));
            CGPoint to = CGPointMake(RDArgNum(a, @"x2", 0), RDArgNum(a, @"y2", 0));
            return @{@"ok": @(RDSwipe(from, to, RDArgNum(a, @"duration", 0.25)))};
        });

    RDRegisterTool(@"ui.setText", @"填写输入框",
        @"给第 n 个输入框填字（会自动聚焦）",
        @[P(@"text", @"string", YES, @"要填的内容"),
          P(@"index", @"number", NO, @"第几个输入框，默认 0")], @"点", ^id(NSDictionary *a) {
            NSString *text = RDArgStr(a, @"text", @"");
            __block BOOL ok = NO;
            RDRunOnMain(^id{
                UIView *v = RDFindTextField(RDArgInt(a, @"index", 0));
                if (!v) return (id)nil;
                if ([v isKindOfClass:[UITextField class]]) {
                    UITextField *tf = (UITextField *)v;
                    [tf becomeFirstResponder];
                    tf.text = text;
                    [tf sendActionsForControlEvents:UIControlEventEditingChanged];
                    ok = YES;
                } else if ([v isKindOfClass:[UITextView class]]) {
                    UITextView *tv = (UITextView *)v;
                    [tv becomeFirstResponder];
                    tv.text = text;
                    ok = YES;
                }
                return (id)nil;
            });
            return @{@"ok": @(ok), @"text": text};
        });

    RDRegisterTool(@"ui.commit", @"提交输入",
        @"让当前输入框触发 return（搜索/确认）",
        @[], @"点", ^id(NSDictionary *a) {
            __block BOOL ok = NO;
            RDRunOnMain(^id{
                UIView *fv = [RDKeyWindow() findFirstResponder];
                if ([fv isKindOfClass:[UITextField class]]) {
                    [(UITextField *)fv sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
                    ok = YES;
                } else if (fv) {
                    [fv resignFirstResponder];
                    ok = YES;
                }
                return (id)nil;
            });
            return @{@"ok": @(ok)};
        });

    RDRegisterTool(@"ui.back", @"返回",
        @"导航栈 pop，或点左上角返回按钮",
        @[], @"点", ^id(NSDictionary *a) {
            __block BOOL ok = NO;
            RDRunOnMain(^id{
                UIWindow *w = RDKeyWindow();
                UIViewController *vc = w.rootViewController;
                while (vc.presentedViewController) vc = vc.presentedViewController;
                if ([vc isKindOfClass:[UINavigationController class]]) {
                    UINavigationController *nav = (UINavigationController *)vc;
                    if (nav.viewControllers.count > 1) {
                        [nav popViewControllerAnimated:YES];
                        ok = YES;
                    }
                } else if (vc.presentingViewController) {
                    [vc dismissViewControllerAnimated:YES completion:nil];
                    ok = YES;
                }
                return (id)nil;
            });
            if (!ok) {
                UIView *v = RDFindViewByText(@"返回", 0);
                if (!v) v = RDFindViewByText(@"Back", 0);
                if (v) ok = RDTapView(v);
            }
            return @{@"ok": @(ok)};
        });

    RDRegisterTool(@"ui.dismissKeyboard", @"收键盘",
        @"结束当前编辑",
        @[], @"点", ^id(NSDictionary *a) {
            __block BOOL ok = NO;
            RDRunOnMain(^id{
                ok = [RDKeyWindow() endEditing:YES];
                return (id)nil;
            });
            return @{@"ok": @(ok)};
        });

    // ---------- 系统 ----------
    RDRegisterTool(@"device.vibrate", @"震动",
        @"来一下震动反馈",
        @[], @"系统", ^id(NSDictionary *a) {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
            return @{@"ok": @YES};
        });

    RDRegisterTool(@"pasteboard.get", @"读剪贴板",
        @"", @[], @"系统", ^id(NSDictionary *a) {
            __block NSString *s = nil;
            RDRunOnMain(^id{ s = [UIPasteboard generalPasteboard].string; return (id)nil; });
            return s ?: @"";
        });

    RDRegisterTool(@"pasteboard.set", @"写剪贴板",
        @"", @[P(@"text", @"string", YES, @"内容")], @"系统", ^id(NSDictionary *a) {
            NSString *s = RDArgStr(a, @"text", @"");
            RDRunOnMain(^id{ [UIPasteboard generalPasteboard].string = s; return (id)nil; });
            return @{@"ok": @YES};
        });

    RDRegisterTool(@"app.openURL", @"打开链接",
        @"", @[P(@"url", @"string", YES, @"URL")], @"系统", ^id(NSDictionary *a) {
            NSString *s = RDArgStr(a, @"url", nil);
            NSURL *u = s.length ? [NSURL URLWithString:s] : nil;
            if (!u) return @{@"ok": @NO, @"error": @"url 不合法"};
            __block BOOL ok = NO;
            RDRunOnMain(^id{
                [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
                ok = YES;
                return (id)nil;
            });
            return @{@"ok": @(ok)};
        });

    RDRegisterTool(@"app.restart", @"重启 app",
        @"退出进程。重新打开后 hooks.json / tools.json 会自动加载，改动继续生效",
        @[P(@"confirm", @"bool", NO, @"传 true 才真的退")], @"系统", ^id(NSDictionary *a) {
            if (!RDArgBool(a, @"confirm", NO)) {
                return @{@"ok": @NO, @"hint": @"加 confirm=true 才会退出"};
            }
            RDLogAppend(@"[APP] restart requested");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ exit(0); });
            return @{@"ok": @YES, @"hint": @"0.4 秒后退出"};
        });

    RDRegisterTool(@"alert.show", @"弹提示",
        @"在界面上弹一个 alert",
        @[P(@"title", @"string", NO, @"标题"),
          P(@"msg", @"string", NO, @"内容")], @"系统", ^id(NSDictionary *a) {
            NSString *t = RDArgStr(a, @"title", @"提示");
            NSString *m = RDArgStr(a, @"msg", @"");
            __block BOOL ok = NO;
            RDRunOnMain(^id{
                UIAlertController *ac =
                    [UIAlertController alertControllerWithTitle:t message:m
                                                 preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                                       style:UIAlertActionStyleDefault
                                                     handler:nil]];
                UIViewController *vc = RDKeyWindow().rootViewController;
                while (vc.presentedViewController) vc = vc.presentedViewController;
                [vc presentViewController:ac animated:YES completion:nil];
                ok = YES;
                return (id)nil;
            });
            return @{@"ok": @(ok)};
        });
}

@implementation UIView (RDFindFirstResponder)
- (UIView *)findFirstResponder {
    if (self.isFirstResponder) return self;
    for (UIView *sub in self.subviews) {
        UIView *r = [sub findFirstResponder];
        if (r) return r;
    }
    return nil;
}
@end

void RDRegisterBuiltinTools(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    RDToolRegisterUIGroup();
}
