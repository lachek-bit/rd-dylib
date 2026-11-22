//
//  RD.h —— RemoteDebug 内部共享声明
//

#ifndef RD_H
#define RD_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#pragma mark - 日志

void RDLogAppend(NSString *s);
NSArray *RDLogsSince(NSUInteger since, NSUInteger *nextOut);
void RDLogClear(void);

#pragma mark - UI 线程 / 窗口

id RDRunOnMain(id (^blk)(void));
UIWindow *RDKeyWindow(void);
NSString *RDUIDump(void);
NSString *RDUIDumpVC(void);
NSData *RDScreenshotJPEG(CGFloat quality);

#pragma mark - 网页

NSString *RDIndexHTML(void);

#pragma mark - 动态 hook

// mode: log | skip | force | after
//   log   —— 只记录调用，原样转发
//   skip  —— 不调原实现，返回零值
//   force —— 不调原实现，返回 value
//   after —— 调原实现，把返回值改成 value
BOOL RDHookInstall(NSString *clsName, NSString *selName, NSString *mode,
                   id value, NSString **errOut);
BOOL RDHookRemove(NSString *clsName, NSString *selName);
NSArray *RDHookList(void);
void RDHookLoadPersisted(void);
BOOL RDBootCheck(void);
extern BOOL gRDCrashLoop;
BOOL RDHookPersist(void);
void RDHookResetAll(void);

#pragma mark - 反射

NSArray *RDClassMethods(NSString *clsName, BOOL includeSuper);
NSArray *RDClassProperties(NSString *clsName, BOOL includeSuper);
NSArray *RDClassIvars(NSString *clsName);
NSArray *RDFindInstances(NSString *clsName, NSUInteger limit);
NSString *RDDescribeObject(id obj);

#pragma mark - 持久化目录

NSString *RDDataDir(void);

#pragma mark - JS 执行

NSString *RDEvalSource(NSString *code);

#pragma mark - 自动化 / 触摸注入

BOOL RDIsHIDReady(void);
BOOL RDInjectTouch(CGPoint p, BOOL down);      // 注入真实触摸（IOHIDEvent）
BOOL RDTapPoint(CGPoint p);                    // 屏幕坐标点一下
BOOL RDTapView(UIView *v);                     // 点某个控件
BOOL RDSwipe(CGPoint from, CGPoint to, NSTimeInterval duration);
CGRect RDScreenRectOfView(UIView *v);          // 转屏幕坐标
UIView *RDFindViewByText(NSString *text, NSInteger index);
UIView *RDFindViewByIdent(NSString *ident, NSInteger index);
UIView *RDFindTextField(NSInteger index);
NSArray *RDInteractiveTree(void);              // 精简可交互元素表

#pragma mark - 工具注册表

typedef id (^RDToolHandler)(NSDictionary *args);

void RDRegisterBuiltinTools(void);
void RDRegisterTool(NSString *name, NSString *title, NSString *desc,
                    NSArray<NSDictionary *> *params, NSString *group,
                    RDToolHandler handler);
id RDCallTool(NSString *name, NSDictionary *args, NSString **err);
NSArray *RDToolList(void);
BOOL RDDefineJSTool(NSDictionary *def, NSString **err);
BOOL RDDeleteTool(NSString *name);
void RDToolLoadPersisted(void);
BOOL RDToolPersist(void);
BOOL RDToolIsBuiltin(NSString *name);

#endif /* RD_H */
