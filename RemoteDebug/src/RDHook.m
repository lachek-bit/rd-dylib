//
//  RDHook.m
//  运行时方法 hook 引擎 + 反射工具
//
//  设计要点：
//  1. 用 imp_implementationWithBlock 替换 IMP，block 返回 void* 而不是 id，
//     避免 ARC 对伪造指针做 retain；整数/对象/BOOL 返回值都靠 x0 传递，天然兼容。
//  2. _cmd 不会传给 block（imp_implementationWithBlock 的约定），所以存在规则对象里。
//  3. 参数按位转发：arm64 上前 6 个参数都在寄存器里，声明成 id 再传回去
//     寄存器内容不变，所以对整数/对象参数都是安全的。
//  4. 规则落盘到 hooks.json，启动时自动重新安装 —— 重启 app 依然生效。
//

#import "RD.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - 规则对象

@interface RDHookRule : NSObject
@property (nonatomic, copy) NSString *clsName;
@property (nonatomic, copy) NSString *selName;
@property (nonatomic, copy) NSString *mode;
@property (nonatomic, strong) id value;
@property (nonatomic, assign) IMP origIMP;
@property (nonatomic, assign) char *types;
@property (nonatomic, assign) SEL sel;
@property (nonatomic, assign) char retType;
@property (nonatomic, assign) BOOL classMethod;
@property (nonatomic, assign) BOOL floatReturn;
@property (nonatomic, strong) id blockObj;
@property (nonatomic, assign) NSUInteger hits;
@property (nonatomic, assign) NSUInteger logged;
@end

@implementation RDHookRule
- (void)dealloc {
    if (_types) { free(_types); _types = NULL; }
}
@end

static NSMutableDictionary<NSString *, RDHookRule *> *gRules = nil;
static pthread_mutex_t gRuleLock = PTHREAD_MUTEX_INITIALIZER;

static NSString *RDKey(NSString *c, NSString *s) {
    return [[c stringByAppendingString:@"|"] stringByAppendingString:s];
}

#pragma mark - 调用日志

static NSString *RDFormatCall(RDHookRule *r, id self, __unsafe_unretained id *argv, NSUInteger argc) {
    if (!r.types) return @"[HOOK] <no types>";
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:r.types];
    NSMutableString *s = [NSMutableString stringWithFormat:@"[HOOK] %c[%@ %@]",
                          r.classMethod ? '+' : '-', r.clsName, r.selName];
    NSUInteger n = sig ? sig.numberOfArguments : 0;
    for (NSUInteger i = 2; i < n; i++) {
        const char *t = [sig getArgumentTypeAtIndex:i];
        id v = (i - 2) < argc ? argv[i - 2] : nil;
        if (t && t[0] == '@') {
            NSString *d = nil;
            @try { d = [v description]; } @catch (NSException *e) { d = nil; }
            if (d.length > 180) d = [[d substringToIndex:180] stringByAppendingString:@"…"];
            [s appendFormat:@" %@", d ?: @"<nil>"];
        } else if (t && (t[0] == 'i' || t[0] == 'q' || t[0] == 'l' ||
                         t[0] == 'B' || t[0] == 's' || t[0] == 'c')) {
            [s appendFormat:@" %lld", (long long)(intptr_t)(__bridge void *)v];
        } else {
            [s appendFormat:@" <%p>", (void *)v];
        }
    }
    return s;
}

#pragma mark - 转发到原实现

static void *RDCallOrigPtr(RDHookRule *r, id self,
                           id a1, id a2, id a3, id a4, id a5) {
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:r.types];
    NSUInteger argc = sig ? (sig.numberOfArguments - 2) : 0;
    IMP imp = r.origIMP;
    SEL cmd = r.sel;
    switch (argc) {
        case 0: return ((void *(*)(id, SEL))imp)(self, cmd);
        case 1: return ((void *(*)(id, SEL, id))imp)(self, cmd, a1);
        case 2: return ((void *(*)(id, SEL, id, id))imp)(self, cmd, a1, a2);
        case 3: return ((void *(*)(id, SEL, id, id, id))imp)(self, cmd, a1, a2, a3);
        case 4: return ((void *(*)(id, SEL, id, id, id, id))imp)(self, cmd, a1, a2, a3, a4);
        case 5: return ((void *(*)(id, SEL, id, id, id, id, id))imp)(self, cmd, a1, a2, a3, a4, a5);
        default: return NULL;
    }
}

static double RDCallOrigDouble(RDHookRule *r, id self,
                               id a1, id a2, id a3, id a4, id a5) {
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:r.types];
    NSUInteger argc = sig ? (sig.numberOfArguments - 2) : 0;
    IMP imp = r.origIMP;
    SEL cmd = r.sel;
    switch (argc) {
        case 0: return ((double (*)(id, SEL))imp)(self, cmd);
        case 1: return ((double (*)(id, SEL, id))imp)(self, cmd, a1);
        case 2: return ((double (*)(id, SEL, id, id))imp)(self, cmd, a1, a2);
        case 3: return ((double (*)(id, SEL, id, id, id))imp)(self, cmd, a1, a2, a3);
        case 4: return ((double (*)(id, SEL, id, id, id, id))imp)(self, cmd, a1, a2, a3, a4);
        case 5: return ((double (*)(id, SEL, id, id, id, id, id))imp)(self, cmd, a1, a2, a3, a4, a5);
        default: return 0;
    }
}

static void *RDForceValue(RDHookRule *r) {
    if (!r.value) return NULL;
    if (r.retType == '@') return (__bridge void *)r.value;
    return (void *)(intptr_t)[r.value longLongValue];
}

#pragma mark - hook 主体

static void *RDGenericHook(RDHookRule *rule, id self,
                           id a1, id a2, id a3, id a4, id a5, id a6) {
    rule.hits++;
    if (rule.logged < 200) {
        rule.logged++;
        __unsafe_unretained id argv[6] = {a1, a2, a3, a4, a5, a6};
        RDLogAppend(RDFormatCall(rule, self, argv, 6));
    }

    NSString *m = rule.mode;
    if ([m isEqualToString:@"skip"])  return NULL;
    if ([m isEqualToString:@"force"]) return RDForceValue(rule);

    void *ret = RDCallOrigPtr(rule, self, a1, a2, a3, a4, a5);
    if ([m isEqualToString:@"after"]) {
        if (rule.value) return RDForceValue(rule);
    }
    return ret;
}

static double RDFloatHook(RDHookRule *rule, id self,
                          id a1, id a2, id a3, id a4, id a5, id a6) {
    rule.hits++;
    if (rule.logged < 200) {
        rule.logged++;
        __unsafe_unretained id argv[6] = {a1, a2, a3, a4, a5, a6};
        RDLogAppend(RDFormatCall(rule, self, argv, 6));
    }

    NSString *m = rule.mode;
    if ([m isEqualToString:@"skip"])  return 0.0;
    if ([m isEqualToString:@"force"]) return rule.value ? [rule.value doubleValue] : 0.0;
    double ret = RDCallOrigDouble(rule, self, a1, a2, a3, a4, a5);
    if ([m isEqualToString:@"after"] && rule.value) return [rule.value doubleValue];
    return ret;
}

#pragma mark - 安装 / 移除

BOOL RDHookInstall(NSString *clsName, NSString *selName, NSString *mode,
                   id value, NSString **errOut) {
    if (!clsName.length || !selName.length) {
        if (errOut) *errOut = @"cls / sel 不能为空";
        return NO;
    }

    Class cls = NSClassFromString(clsName);
    if (!cls) {
        if (errOut) *errOut = [NSString stringWithFormat:@"类 %@ 不存在", clsName];
        return NO;
    }

    SEL sel = NSSelectorFromString(selName);
    if (!sel) {
        if (errOut) *errOut = [NSString stringWithFormat:@"selector %@ 非法", selName];
        return NO;
    }

    Method m = class_getInstanceMethod(cls, sel);
    BOOL isClsMethod = NO;
    Class holder = cls;
    if (!m) {
        m = class_getClassMethod(cls, sel);
        isClsMethod = YES;
        holder = object_getClass(cls);
    }
    if (!m) {
        if (errOut) *errOut = [NSString stringWithFormat:@"%@ 上找不到 %@", clsName, selName];
        return NO;
    }

    NSString *key = RDKey(clsName, selName);
    RDHookRule *old = nil;
    pthread_mutex_lock(&gRuleLock);
    old = [gRules objectForKey:key];
    pthread_mutex_unlock(&gRuleLock);
    if (old) {
        // 已 hook 过，只更新行为
        old.mode = mode.length ? mode : @"log";
        old.value = value;
        if (errOut) *errOut = @"";
        return YES;
    }

    const char *retTypeStr = method_copyReturnType(m);
    char rt = retTypeStr ? retTypeStr[0] : 'v';
    if (retTypeStr) free((void *)retTypeStr);

    // 结构体返回（{ 开头）不支持，跳转会产生野内存
    if (rt == '{' || rt == '(' || rt == '[') {
        if (errOut) *errOut = @"返回结构体/数组的方法暂不支持 hook";
        return NO;
    }

    RDHookRule *r = [RDHookRule new];
    r.clsName = clsName;
    r.selName = selName;
    r.sel = sel;
    r.mode = mode.length ? mode : @"log";
    r.value = value;
    r.origIMP = method_getImplementation(m);
    r.retType = rt;
    r.classMethod = isClsMethod;
    r.floatReturn = (rt == 'd' || rt == 'f');
    const char *te = method_getTypeEncoding(m);
    r.types = te ? strdup(te) : NULL;

    IMP newIMP = NULL;
    if (r.floatReturn) {
        r.blockObj = ^double(id self, id a1, id a2, id a3, id a4, id a5, id a6) {
            return RDFloatHook(r, self, a1, a2, a3, a4, a5, a6);
        };
    } else {
        r.blockObj = ^void *(id self, id a1, id a2, id a3, id a4, id a5, id a6) {
            return RDGenericHook(r, self, a1, a2, a3, a4, a5, a6);
        };
    }
    newIMP = imp_implementationWithBlock(r.blockObj);
    if (!newIMP) {
        if (errOut) *errOut = @"imp_implementationWithBlock 失败";
        return NO;
    }

    // class_replaceMethod 会优先在 holder 自己的方法表上添加/替换，
    // 不会污染父类实现
    class_replaceMethod(holder, sel, newIMP, r.types);

    pthread_mutex_lock(&gRuleLock);
    if (!gRules) gRules = [NSMutableDictionary dictionary];
    gRules[key] = r;
    pthread_mutex_unlock(&gRuleLock);

    RDLogAppend([NSString stringWithFormat:@"[HOOK+] %c[%@ %@] mode=%@ ret=%c",
                 isClsMethod ? '+' : '-', clsName, selName, r.mode, rt]);
    if (errOut) *errOut = @"";
    return YES;
}

BOOL RDHookRemove(NSString *clsName, NSString *selName) {
    NSString *key = RDKey(clsName, selName);
    pthread_mutex_lock(&gRuleLock);
    RDHookRule *r = gRules[key];
    [gRules removeObjectForKey:key];
    pthread_mutex_unlock(&gRuleLock);
    if (!r) return NO;

    Class cls = NSClassFromString(clsName);
    if (!cls) return NO;
    Class holder = r.classMethod ? object_getClass(cls) : cls;
    Method m = r.classMethod ? class_getClassMethod(cls, r.sel) : class_getInstanceMethod(holder, r.sel);
    if (m) method_setImplementation(m, r.origIMP);

    RDLogAppend([NSString stringWithFormat:@"[HOOK-] %@ %@ (hits=%lu)",
                 clsName, selName, (unsigned long)r.hits]);
    return YES;
}

NSArray *RDHookList(void) {
    NSMutableArray *out = [NSMutableArray array];
    pthread_mutex_lock(&gRuleLock);
    for (NSString *k in gRules) {
        RDHookRule *r = gRules[k];
        [out addObject:@{
            @"cls": r.clsName ?: @"",
            @"sel": r.selName ?: @"",
            @"mode": r.mode ?: @"log",
            @"class_method": @(r.classMethod),
            @"hits": @(r.hits),
            @"ret": [NSString stringWithFormat:@"%c", r.retType]
        }];
    }
    pthread_mutex_unlock(&gRuleLock);
    return out;
}

void RDHookResetAll(void) {
    NSArray *keys = nil;
    pthread_mutex_lock(&gRuleLock);
    keys = [gRules allKeys];
    pthread_mutex_unlock(&gRuleLock);
    for (NSString *k in keys) {
        NSArray *parts = [k componentsSeparatedByString:@"|"];
        if (parts.count == 2) RDHookRemove(parts[0], parts[1]);
    }
}

#pragma mark - 持久化

NSString *RDDataDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"unknown";
        NSString *global = [NSString stringWithFormat:
                            @"/var/mobile/Library/RemoteDebug/%@", bid];
        NSError *e = nil;
        if ([fm createDirectoryAtPath:global withIntermediateDirectories:YES
                           attributes:nil error:&e]) {
            dir = global;
        } else {
            NSString *alt = [NSHomeDirectory()
                             stringByAppendingPathComponent:@"Documents/RemoteDebug"];
            [fm createDirectoryAtPath:alt withIntermediateDirectories:YES
                           attributes:nil error:nil];
            dir = alt;
        }
    });
    return dir;
}

static NSString *RDHooksPath(void) {
    return [RDDataDir() stringByAppendingPathComponent:@"hooks.json"];
}

BOOL RDHookPersist(void) {
    NSMutableArray *arr = [NSMutableArray array];
    pthread_mutex_lock(&gRuleLock);
    for (NSString *k in gRules) {
        RDHookRule *r = gRules[k];
        NSMutableDictionary *d = [@{
            @"cls": r.clsName ?: @"",
            @"sel": r.selName ?: @"",
            @"mode": r.mode ?: @"log"
        } mutableCopy];
        if (r.value) {
            // 只持久化能序列化的值
            if ([r.value isKindOfClass:[NSNumber class]] ||
                [r.value isKindOfClass:[NSString class]]) {
                d[@"value"] = r.value;
            }
        }
        [arr addObject:d];
    }
    pthread_mutex_unlock(&gRuleLock);

    NSData *jd = [NSJSONSerialization dataWithJSONObject:arr options:NSJSONWritingPrettyPrinted error:nil];
    if (!jd) return NO;
    return [jd writeToFile:RDHooksPath() atomically:YES];
}

void RDHookLoadPersisted(void) {
    NSString *path = RDHooksPath();
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d.length) return;

    NSArray *arr = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![arr isKindOfClass:[NSArray class]]) return;

    NSUInteger ok = 0;
    for (NSDictionary *item in arr) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *cls = item[@"cls"], *sel = item[@"sel"], *mode = item[@"mode"];
        id value = item[@"value"];
        NSString *err = nil;
        if (RDHookInstall(cls, sel, mode, value, &err)) ok++;
        else RDLogAppend([NSString stringWithFormat:@"[HOOK!] 恢复失败 %@ %@: %@", cls, sel, err]);
    }
    if (ok) RDLogAppend([NSString stringWithFormat:@"[HOOK] 已从 hooks.json 恢复 %lu 条规则", (unsigned long)ok]);
}

#pragma mark - 反射

static void RDCollectMethods(Class cls, BOOL classMethod, NSMutableArray *out) {
    unsigned int n = 0;
    Class target = classMethod ? object_getClass(cls) : cls;
    Method *ms = class_copyMethodList(target, &n);
    if (!ms) return;
    for (unsigned int i = 0; i < n; i++) {
        const char *name = sel_getName(method_getName(ms[i]));
        const char *types = method_getTypeEncoding(ms[i]);
        if (!name) continue;
        [out addObject:@{
            @"name": @(name),
            @"types": types ? @(types) : @"",
            @"class_method": @(classMethod),
            @"owner": NSStringFromClass(cls) ?: @""
        }];
    }
    free(ms);
}

NSArray *RDClassMethods(NSString *clsName, BOOL includeSuper) {
    Class cls = NSClassFromString(clsName);
    if (!cls) return @[];
    NSMutableArray *out = [NSMutableArray array];
    Class cur = cls;
    int depth = 0;
    while (cur && depth < 12) {
        if (!includeSuper && depth > 0) break;
        RDCollectMethods(cur, NO, out);
        RDCollectMethods(cur, YES, out);
        cur = class_getSuperclass(cur);
        depth++;
    }
    return out;
}

NSArray *RDClassProperties(NSString *clsName, BOOL includeSuper) {
    Class cls = NSClassFromString(clsName);
    if (!cls) return @[];
    NSMutableArray *out = [NSMutableArray array];
    Class cur = cls;
    int depth = 0;
    while (cur && depth < 12) {
        if (!includeSuper && depth > 0) break;
        unsigned int n = 0;
        objc_property_t *ps = class_copyPropertyList(cur, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *name = property_getName(ps[i]);
            const char *attrs = property_getAttributes(ps[i]);
            if (!name) continue;
            [out addObject:@{
                @"name": @(name),
                @"attrs": attrs ? @(attrs) : @"",
                @"owner": NSStringFromClass(cur) ?: @""
            }];
        }
        if (ps) free(ps);
        cur = class_getSuperclass(cur);
        depth++;
    }
    return out;
}

NSArray *RDClassIvars(NSString *clsName) {
    Class cls = NSClassFromString(clsName);
    if (!cls) return @[];
    NSMutableArray *out = [NSMutableArray array];
    unsigned int n = 0;
    Ivar *ivs = class_copyIvarList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        const char *name = ivar_getName(ivs[i]);
        const char *type = ivar_getTypeEncoding(ivs[i]);
        if (!name) continue;
        [out addObject:@{@"name": @(name), @"type": type ? @(type) : @""}];
    }
    if (ivs) free(ivs);
    return out;
}

NSString *RDDescribeObject(id obj) {
    if (!obj) return @"<nil>";
    NSString *d = nil;
    @try { d = [obj description]; } @catch (NSException *e) { d = nil; }
    if (!d) d = @"";
    if (d.length > 400) d = [[d substringToIndex:400] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@"%@ <%p> %@",
            NSStringFromClass([obj class]), (void *)obj, d];
}

static void RDScanViewTree(UIView *v, Class cls, NSMutableArray *out, NSUInteger limit) {
    if (!v || out.count >= limit) return;
    if ([v isKindOfClass:cls]) {
        [out addObject:@{
            @"ptr": [NSString stringWithFormat:@"0x%lx", (unsigned long)(uintptr_t)(__bridge void *)v],
            @"cls": NSStringFromClass([v class]) ?: @"",
            @"desc": RDDescribeObject(v)
        }];
    }
    for (UIView *sub in v.subviews) RDScanViewTree(sub, cls, out, limit);
}

static void RDScanVC(UIViewController *vc, Class cls, NSMutableArray *out, NSUInteger limit) {
    if (!vc || out.count >= limit) return;
    if ([vc isKindOfClass:cls]) {
        [out addObject:@{
            @"ptr": [NSString stringWithFormat:@"0x%lx", (unsigned long)(uintptr_t)(__bridge void *)vc],
            @"cls": NSStringFromClass([vc class]) ?: @"",
            @"desc": RDDescribeObject(vc)
        }];
    }
    for (UIViewController *child in vc.childViewControllers) RDScanVC(child, cls, out, limit);
    if (vc.presentedViewController) RDScanVC(vc.presentedViewController, cls, out, limit);
}

NSArray *RDFindInstances(NSString *clsName, NSUInteger limit) {
    Class cls = NSClassFromString(clsName);
    if (!cls) return @[];
    if (limit == 0) limit = 50;

    NSMutableArray *out = [NSMutableArray array];
    RDRunOnMain(^id{
        UIWindow *w = RDKeyWindow();
        if (!w) return (id)nil;
        // 视图树
        if ([cls isSubclassOfClass:[UIView class]] || cls == [UIView class]) {
            RDScanViewTree(w, cls, out, limit);
        }
        // 控制器树
        if ([cls isSubclassOfClass:[UIViewController class]] || cls == [UIViewController class]) {
            RDScanVC(w.rootViewController, cls, out, limit);
        }
        return (id)nil;
    });
    return out;
}
