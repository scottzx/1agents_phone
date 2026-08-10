//
//  ISHShellExecutor.h
//  iSH
//
//  Shell execution interface with line-by-line output and process completion
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ISHShellExecutorError) {
    ISHShellExecutorErrorNone = 0,
    ISHShellExecutorErrorProcessCreationFailed = -1,
    ISHShellExecutorErrorExecFailed = -2,
    ISHShellExecutorErrorTimeout = -3,
    ISHShellExecutorErrorCancelled = -4,
};

@interface ISHShellExecutionResult : NSObject

/// Exit code of the shell process (0 = success)
@property (nonatomic, readonly) int exitCode;

/// Guest process PID
@property (nonatomic, readonly) int pid;

/// Error code if execution failed
@property (nonatomic, readonly) ISHShellExecutorError error;

/// Complete stdout output (all lines joined)
@property (nonatomic, readonly, copy) NSString *output;

/// Complete stderr output (all lines joined)
@property (nonatomic, readonly, copy) NSString *errorOutput;

/// Execution duration in seconds
@property (nonatomic, readonly) NSTimeInterval duration;

@end

/// Line callback block: called for each line of output
/// @param line The output line (without newline)
/// @param isStdErr YES if from stderr, NO if from stdout
typedef void (^ISHShellLineCallback)(NSString *line, BOOL isStdErr);

/// Completion callback block: called when process exits
/// @param result Execution result containing exit code and outputs
typedef void (^ISHShellCompletionCallback)(ISHShellExecutionResult *result);

@interface ISHShellExecutor : NSObject

/// Execute a shell command with line-by-line output callback
/// @param command Shell command to execute (will be passed to /bin/sh -c)
/// @param lineCallback Called for each line of output (on main queue), can be nil
/// @param completion Called when process exits (on main queue), can be nil
/// @return Guest process PID, or negative error code on failure
+ (int)executeCommand:(NSString *)command
         lineCallback:(nullable ISHShellLineCallback)lineCallback
           completion:(nullable ISHShellCompletionCallback)completion;

/// Execute a shell command with array of arguments
/// @param executable Path to executable (e.g., "/bin/ls")
/// @param arguments Array of arguments (e.g., @[@"-la", @"/tmp"])
/// @param environment Dictionary of environment variables (nil = default)
/// @param lineCallback Called for each line of output (on main queue), can be nil
/// @param completion Called when process exits (on main queue), can be nil
/// @return Guest process PID, or negative error code on failure
+ (int)executeExecutable:(NSString *)executable
               arguments:(nullable NSArray<NSString *> *)arguments
             environment:(nullable NSDictionary<NSString *, NSString *> *)environment
            lineCallback:(nullable ISHShellLineCallback)lineCallback
              completion:(nullable ISHShellCompletionCallback)completion;

/// Execute an executable with data fed to stdin via pipe.
/// @param executable Path to executable (e.g., "/bin/sh")
/// @param arguments Array of arguments (e.g., @[])
/// @param environment Dictionary of environment variables (nil = default)
/// @param stdinData Data to write to the process's stdin (pipe is closed after write)
/// @param lineCallback Called for each line of output (on main queue), can be nil
/// @param completion Called when process exits (on main queue), can be nil
/// @return Guest process PID, or negative error code on failure
+ (int)executeExecutable:(NSString *)executable
               arguments:(nullable NSArray<NSString *> *)arguments
             environment:(nullable NSDictionary<NSString *, NSString *> *)environment
               stdinData:(nullable NSData *)stdinData
            lineCallback:(nullable ISHShellLineCallback)lineCallback
              completion:(nullable ISHShellCompletionCallback)completion;

/// Execute an executable, stamping the new task group with an opaque
/// fs_context value before exec. The value is inherited by all children
/// and is visible to the fakefs path-translate hook via
/// current->group->fs_context. Passing 0 is equivalent to the methods
/// above and gives the default global view.
/// @param fsContext Opaque context value (0 = no override)
+ (int)executeExecutable:(NSString *)executable
               arguments:(nullable NSArray<NSString *> *)arguments
             environment:(nullable NSDictionary<NSString *, NSString *> *)environment
               stdinData:(nullable NSData *)stdinData
               fsContext:(uint64_t)fsContext
            lineCallback:(nullable ISHShellLineCallback)lineCallback
              completion:(nullable ISHShellCompletionCallback)completion;

/// Execute a shell command and wait synchronously for completion
/// @param command Shell command to execute
/// @param timeout Maximum wait time in seconds (0 = no timeout)
/// @param lineCallback Called for each line of output, can be nil
/// @return Execution result
+ (ISHShellExecutionResult *)executeCommandSync:(NSString *)command
                                        timeout:(NSTimeInterval)timeout
                                   lineCallback:(nullable ISHShellLineCallback)lineCallback;

/// Kill a running process
/// @param pid Guest process PID (returned from execute methods)
/// @param signal Signal to send (default: SIGKILL)
/// @return YES if process was found and signaled
+ (BOOL)killProcess:(int)pid withSignal:(int)signal;

/// Kill a process and all children in its process group.
/// First sends SIGTERM to the group, waits briefly, then sends SIGKILL.
/// @param pid Guest process PID — its pgid is used to find the group
+ (void)killProcessGroup:(int)pid;

@end

#pragma mark - Persistent Process

/// A long-lived guest process whose stdin pipe stays open after launch, so the
/// host can keep writing commands and stream stdout/stderr line-by-line.
/// Used for daemon-style runtimes (e.g. `pi --mode rpc`).
@interface ISHShellPersistentProcess : NSObject

/// Guest process PID (returned by the launch method).
@property (nonatomic, readonly) int pid;

/// Write end of the guest's stdin pipe. Owned by this object; do NOT close it
/// yourself — call -terminate or dealloc instead.
@property (nonatomic, readonly) int stdinWriteFD;

/// Write a chunk of data to the process's stdin (blocking until fully written).
/// @return YES on success, NO if the pipe is closed or the write failed.
- (BOOL)writeData:(NSData *)data;

/// Write a line to stdin, appending "\n" (RPC mode is newline-delimited JSON).
/// @return YES on success, NO if the pipe is closed or the write failed.
- (BOOL)writeLine:(NSString *)line;

/// Send SIGTERM then SIGKILL to the process and its whole group (children
/// included), then close the stdin pipe. Safe to call multiple times.
- (void)terminate;

@end

/// Line callback for persistent processes (called on the main queue).
typedef void (^ISHShellPersistentLineCallback)(NSString *line, BOOL isStdErr);

/// Exit callback for persistent processes (called on the main queue).
typedef void (^ISHShellPersistentExitCallback)(int exitCode, int guestPid);

@interface ISHShellExecutor (Persistent)

/// Launch a long-lived executable with an open stdin pipe.
/// @param executable Path to executable (e.g. "/usr/local/bin/pi")
/// @param arguments Array of arguments (e.g. @[@"--mode", @"rpc"])
/// @param environment Dictionary of environment variables (nil = default)
/// @param fsContext Opaque per-session context (0 = default), stamped on the
///        new task group like the one-shot methods
/// @param lineCallback Called per stdout/stderr line (main queue), can be nil
/// @param exitCallback Called when the process exits (main queue), can be nil
/// @return A process handle, or nil if the process could not be launched.
+ (nullable ISHShellPersistentProcess *)launchPersistentExecutable:(NSString *)executable
                                                         arguments:(nullable NSArray<NSString *> *)arguments
                                                       environment:(nullable NSDictionary<NSString *, NSString *> *)environment
                                                         fsContext:(uint64_t)fsContext
                                                      lineCallback:(nullable ISHShellPersistentLineCallback)lineCallback
                                                      exitCallback:(nullable ISHShellPersistentExitCallback)exitCallback;

@end

NS_ASSUME_NONNULL_END
