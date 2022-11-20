//
//  UIApplication-KIFAdditions.h
//  KIF
//
//  Created by Eric Firestone on 5/20/11.
//  Licensed to Square, Inc. under one or more contributor license agreements.
//  See the LICENSE file distributed with this work for the terms under
//  which Square, Inc. licenses this file to you.

#import <UIKit/UIKit.h>

#define UIApplicationCurrentRunMode ([[UIApplication sharedApplication] currentRunLoopMode])

/*!
 @abstract When mocking @c -openURL:, this notification is posted.
 */
UIKIT_EXTERN NSString *const UIApplicationDidMockOpenURLNotification;

/*!
 @abstract When mocking @c -canOpenURL:, this notification is posted.
 */
UIKIT_EXTERN NSString *const UIApplicationDidMockCanOpenURLNotification;

/*!
 @abstract The key for the opened URL in the @c UIApplicationDidMockOpenURLNotification notification.
 */
UIKIT_EXTERN NSString *const UIApplicationOpenedURLKey;

@interface UIApplication (KIFAdditions)

/*!
 @returns The window containing the keyboard or @c nil if the keyboard is not visible.
 */
- (UIWindow *)keyboardWindow;

/*!
 @returns The topmost window containing a @c UIDatePicker.
 */
- (UIWindow *)datePickerWindow;

/*!
 @returns The topmost window containing a @c UIPickerView.
 */
- (UIWindow *)pickerViewWindow;

/*!
 @returns The topmost window containing a @c UIDimmingView.
 */
- (UIWindow *)dimmingViewWindow;

/*!
 @returns All windows in the application, including the key window even if it does not appear in @c -windows.
 */
- (NSArray *)windowsWithKeyWindow;

/*!
 @abstract Writes a screenshot to disk.
 @discussion This method only works if the @c KIF_SCREENSHOTS environment variable is set.
 @param lineNumber The line number in the code at which the screenshot was taken.
 @param filename The name of the file in which the screenshot was taken.
 @param description An optional description of the scene being captured.
 @param error If the method returns @c YES, this optional parameter provides additional information as to why it failed.
 @returns @c YES if the screenshot was written to disk, otherwise @c NO.
 */
- (BOOL)writeScreenshotForLine:(NSUInteger)lineNumber inFile:(NSString *)filename description:(NSString *)description error:(NSError **)error;

/*!
 @returns The current run loop mode.
 */
- (CFStringRef)currentRunLoopMode;

/*!
 @abstract Swizzles the run loop modes so KIF can better switch between them.
 */
+ (void)swizzleRunLoop;

/*!
 @abstract Starts mocking requests to @c -openURL:, announcing all requests with a notification.
 @discussion After calling this method, whenever @c -openURL: is called a notification named @c UIApplicationDidMockOpenURLNotification with the URL in the @c UIApplicationOpenedURL will be raised and the normal behavior will be cancelled.
 @param returnValue The value to return when @c -openURL: is called.
 */
+ (void)startMockingOpenURLWithReturnValue:(BOOL)returnValue;

/*!
 @abstract Stops the application from mocking requests to @c -openURL:.
 */
+ (void)stopMockingOpenURL;

@end

@interface UIApplication (Private)
- (UIWindow *)statusBarWindow;
@property(getter=isStatusBarHidden) BOOL statusBarHidden;
@end

@interface UIApplication (KIFAdditionsPrivate)
- (UIEvent *)_touchesEvent;
@end

