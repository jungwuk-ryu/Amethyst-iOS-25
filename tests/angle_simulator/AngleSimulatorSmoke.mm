#import <UIKit/UIKit.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <angle_gl.h>

#include <cstring>
#include <sstream>
#include <string>

namespace
{

struct EGLState
{
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT;

    ~EGLState()
    {
        if (display == EGL_NO_DISPLAY)
        {
            return;
        }
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (context != EGL_NO_CONTEXT)
        {
            eglDestroyContext(display, context);
        }
        if (surface != EGL_NO_SURFACE)
        {
            eglDestroySurface(display, surface);
        }
        eglTerminate(display);
    }
};

std::string GetShaderLog(GLuint shader)
{
    GLint length = 0;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
    if (length <= 1)
    {
        return {};
    }

    std::string log(static_cast<size_t>(length), '\0');
    glGetShaderInfoLog(shader, length, nullptr, log.data());
    return log;
}

std::string GetProgramLog(GLuint program)
{
    GLint length = 0;
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, &length);
    if (length <= 1)
    {
        return {};
    }

    std::string log(static_cast<size_t>(length), '\0');
    glGetProgramInfoLog(program, length, nullptr, log.data());
    return log;
}

bool CompileShader(GLenum type, const char *source, GLuint *shaderOut, std::string *failure)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);

    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled != GL_TRUE)
    {
        std::ostringstream message;
        message << (type == GL_VERTEX_SHADER ? "vertex" : "fragment")
                << " shader compilation failed: " << GetShaderLog(shader);
        *failure = message.str();
        glDeleteShader(shader);
        return false;
    }

    *shaderOut = shader;
    return true;
}

bool CheckGLError(const char *operation, std::string *failure)
{
    GLenum error = glGetError();
    if (error == GL_NO_ERROR)
    {
        return true;
    }

    std::ostringstream message;
    message << operation << " failed with GL error 0x" << std::hex << error;
    *failure = message.str();
    return false;
}

bool CheckPixel(const GLubyte pixel[4],
                GLubyte expectedRed,
                GLubyte expectedGreen,
                GLubyte expectedBlue,
                const char *phase,
                std::string *failure)
{
    if (pixel[0] == expectedRed && pixel[1] == expectedGreen && pixel[2] == expectedBlue &&
        pixel[3] == 255)
    {
        return true;
    }

    std::ostringstream message;
    message << phase << " returned RGBA(" << static_cast<int>(pixel[0]) << ", "
            << static_cast<int>(pixel[1]) << ", " << static_cast<int>(pixel[2]) << ", "
            << static_cast<int>(pixel[3]) << ")";
    *failure = message.str();
    return false;
}

bool RunANGLETextureBufferSmoke(bool noErrorContext, std::string *details)
{
    EGLState egl;
    const EGLAttrib displayAttributes[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE,
        EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_NONE,
    };
    egl.display = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, nullptr, displayAttributes);
    if (egl.display == EGL_NO_DISPLAY)
    {
        std::ostringstream message;
        message << "eglGetPlatformDisplay failed with EGL error 0x" << std::hex << eglGetError();
        *details = message.str();
        return false;
    }

    EGLint eglMajor = 0;
    EGLint eglMinor = 0;
    if (eglInitialize(egl.display, &eglMajor, &eglMinor) != EGL_TRUE)
    {
        std::ostringstream message;
        message << "eglInitialize failed with EGL error 0x" << std::hex << eglGetError();
        *details = message.str();
        return false;
    }

    const EGLint configAttributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RED_SIZE,     8,
        EGL_GREEN_SIZE,   8,
        EGL_BLUE_SIZE,    8,
        EGL_ALPHA_SIZE,   8,
        EGL_NONE,
    };
    EGLConfig config   = nullptr;
    EGLint configCount = 0;
    if (eglChooseConfig(egl.display, configAttributes, &config, 1, &configCount) != EGL_TRUE ||
        configCount != 1)
    {
        std::ostringstream message;
        message << "eglChooseConfig failed with EGL error 0x" << std::hex << eglGetError();
        *details = message.str();
        return false;
    }

    const EGLint surfaceAttributes[] = {
        EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE,
    };
    egl.surface = eglCreatePbufferSurface(egl.display, config, surfaceAttributes);
    if (egl.surface == EGL_NO_SURFACE)
    {
        std::ostringstream message;
        message << "eglCreatePbufferSurface failed with EGL error 0x" << std::hex << eglGetError();
        *details = message.str();
        return false;
    }

    if (eglBindAPI(EGL_OPENGL_API) != EGL_TRUE)
    {
        std::ostringstream message;
        message << "eglBindAPI(EGL_OPENGL_API) failed with EGL error 0x" << std::hex
                << eglGetError();
        *details = message.str();
        return false;
    }

    const EGLint contextAttributes[] = {
        EGL_CONTEXT_MAJOR_VERSION_KHR,
        3,
        EGL_CONTEXT_MINOR_VERSION_KHR,
        3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK_KHR,
        EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR,
        EGL_CONTEXT_OPENGL_NO_ERROR_KHR,
        noErrorContext ? EGL_TRUE : EGL_FALSE,
        EGL_NONE,
    };
    egl.context = eglCreateContext(egl.display, config, EGL_NO_CONTEXT, contextAttributes);
    if (egl.context == EGL_NO_CONTEXT)
    {
        std::ostringstream message;
        message << "eglCreateContext(OpenGL 3.3 core"
                << (noErrorContext ? ", no-error" : ", validation") << ") failed with EGL error 0x"
                << std::hex << eglGetError();
        *details = message.str();
        return false;
    }

    if (eglMakeCurrent(egl.display, egl.surface, egl.surface, egl.context) != EGL_TRUE)
    {
        std::ostringstream message;
        message << "eglMakeCurrent failed with EGL error 0x" << std::hex << eglGetError();
        *details = message.str();
        return false;
    }

    GLint actualMajor = 0;
    GLint actualMinor = 0;
    GLint profileMask = 0;
    glGetIntegerv(GL_MAJOR_VERSION, &actualMajor);
    glGetIntegerv(GL_MINOR_VERSION, &actualMinor);
    glGetIntegerv(GL_CONTEXT_PROFILE_MASK, &profileMask);
    if (actualMajor != 3 || actualMinor < 3 || (profileMask & GL_CONTEXT_CORE_PROFILE_BIT) == 0)
    {
        std::ostringstream message;
        message << "expected OpenGL 3.3 core, got " << actualMajor << "." << actualMinor
                << " with profile mask 0x" << std::hex << profileMask;
        *details = message.str();
        return false;
    }

    constexpr char kVertexShader[] = R"(#version 330 core
const vec2 positions[3] = vec2[3](
    vec2(-1.0, -1.0),
    vec2( 3.0, -1.0),
    vec2(-1.0,  3.0)
);
void main()
{
    gl_Position = vec4(positions[gl_VertexID], 0.0, 1.0);
})";

    constexpr char kFragmentShader[] = R"(#version 330 core
uniform isamplerBuffer bufferTexture;
out vec4 colorOut;
void main()
{
    int value = texelFetch(bufferTexture, 0).r;
    colorOut = value == 7 ? vec4(1.0, 0.0, 0.0, 1.0)
                          : (value == 9 ? vec4(0.0, 1.0, 0.0, 1.0)
                                        : vec4(0.0, 0.0, 1.0, 1.0));
})";

    GLuint vertexShader   = 0;
    GLuint fragmentShader = 0;
    std::string failure;
    if (!CompileShader(GL_VERTEX_SHADER, kVertexShader, &vertexShader, &failure) ||
        !CompileShader(GL_FRAGMENT_SHADER, kFragmentShader, &fragmentShader, &failure))
    {
        if (vertexShader != 0)
        {
            glDeleteShader(vertexShader);
        }
        *details = failure;
        return false;
    }

    GLuint program = glCreateProgram();
    glAttachShader(program, vertexShader);
    glAttachShader(program, fragmentShader);
    glLinkProgram(program);
    glDeleteShader(vertexShader);
    glDeleteShader(fragmentShader);

    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE)
    {
        *details = "program link failed: " + GetProgramLog(program);
        glDeleteProgram(program);
        return false;
    }

    GLuint vertexArray = 0;
    GLuint buffer      = 0;
    GLuint texture     = 0;
    glGenVertexArrays(1, &vertexArray);
    glBindVertexArray(vertexArray);
    glGenBuffers(1, &buffer);
    glBindBuffer(GL_TEXTURE_BUFFER, buffer);
    auto cleanup = [&]() {
        glDeleteTextures(1, &texture);
        glDeleteBuffers(1, &buffer);
        glDeleteVertexArrays(1, &vertexArray);
        glDeleteProgram(program);
    };

    GLbyte value = 7;
    glBufferData(GL_TEXTURE_BUFFER, sizeof(value), &value, GL_DYNAMIC_DRAW);
    if (!CheckGLError("initial glBufferData", &failure))
    {
        *details = failure;
        cleanup();
        return false;
    }
    glGenTextures(1, &texture);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_BUFFER, texture);
    glTexBuffer(GL_TEXTURE_BUFFER, GL_R8I, buffer);
    if (!CheckGLError("initial glTexBuffer(GL_R8I)", &failure))
    {
        *details = failure;
        cleanup();
        return false;
    }

    glUseProgram(program);
    glUniform1i(glGetUniformLocation(program, "bufferTexture"), 0);
    glViewport(0, 0, 16, 16);
    auto drawAndCheck = [&](GLubyte expectedRed, GLubyte expectedGreen, const char *phase) -> bool {
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glFinish();
        GLubyte pixel[4] = {};
        glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
        return CheckGLError(phase, &failure) &&
               CheckPixel(pixel, expectedRed, expectedGreen, 0, phase, &failure);
    };

    if (!drawAndCheck(255, 0, "initial texture-buffer draw"))
    {
        *details = failure;
        cleanup();
        return false;
    }

    value = 9;
    glBufferSubData(GL_TEXTURE_BUFFER, 0, sizeof(value), &value);
    if (!CheckGLError("glBufferSubData", &failure) ||
        !drawAndCheck(0, 255, "glBufferSubData texture-buffer draw"))
    {
        *details = failure;
        cleanup();
        return false;
    }

    GLbyte *mappedValue = static_cast<GLbyte *>(glMapBufferRange(
        GL_TEXTURE_BUFFER, 0, sizeof(value), GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_RANGE_BIT));
    if (mappedValue == nullptr)
    {
        *details = "glMapBufferRange returned null";
        cleanup();
        return false;
    }
    *mappedValue = 7;
    if (glUnmapBuffer(GL_TEXTURE_BUFFER) != GL_TRUE ||
        !CheckGLError("glMapBufferRange/glUnmapBuffer", &failure) ||
        !drawAndCheck(255, 0, "mapped texture-buffer draw"))
    {
        *details = failure.empty() ? "glUnmapBuffer returned GL_FALSE" : failure;
        cleanup();
        return false;
    }

    value = 9;
    glBufferData(GL_TEXTURE_BUFFER, sizeof(value), &value, GL_DYNAMIC_DRAW);
    if (!CheckGLError("reallocation glBufferData", &failure) ||
        !drawAndCheck(0, 255, "reallocated texture-buffer draw"))
    {
        *details = failure;
        cleanup();
        return false;
    }

    constexpr char kRGB32FragmentShader[] = R"(#version 330 core
uniform samplerBuffer floatValues;
uniform isamplerBuffer intValues;
uniform usamplerBuffer uintValues;
out vec4 colorOut;
void main()
{
    vec4 f = texelFetch(floatValues, 1);
    ivec4 i = texelFetch(intValues, 1);
    uvec4 u = texelFetch(uintValues, 1);
    bool validSize = textureSize(floatValues) == 2 &&
                     textureSize(intValues) == 2 &&
                     textureSize(uintValues) == 2;
    bool initial = all(equal(f, vec4(0.25, 0.5, 0.75, 1.0))) &&
                   all(equal(i, ivec4(2, -3, 4, 1))) &&
                   all(equal(u, uvec4(5, 6, 7, 1)));
    bool subData = all(equal(f, vec4(1.25, 1.5, 1.75, 1.0))) &&
                   all(equal(i, ivec4(12, -13, 14, 1))) &&
                   all(equal(u, uvec4(15, 16, 17, 1)));
    bool mapped = all(equal(f, vec4(2.25, 2.5, 2.75, 1.0))) &&
                  all(equal(i, ivec4(22, -23, 24, 1))) &&
                  all(equal(u, uvec4(25, 26, 27, 1)));
    bool reallocated = all(equal(f, vec4(3.25, 3.5, 3.75, 1.0))) &&
                       all(equal(i, ivec4(32, -33, 34, 1))) &&
                       all(equal(u, uvec4(35, 36, 37, 1)));
    colorOut = !validSize ? vec4(1.0, 0.0, 1.0, 1.0)
             : initial ? vec4(0.0, 1.0, 0.0, 1.0)
             : subData ? vec4(0.0, 0.0, 1.0, 1.0)
             : mapped ? vec4(1.0, 0.0, 0.0, 1.0)
             : reallocated ? vec4(1.0, 1.0, 0.0, 1.0)
                           : vec4(1.0, 0.0, 1.0, 1.0);
})";

    GLuint rgbVertexShader   = 0;
    GLuint rgbFragmentShader = 0;
    if (!CompileShader(GL_VERTEX_SHADER, kVertexShader, &rgbVertexShader, &failure) ||
        !CompileShader(GL_FRAGMENT_SHADER, kRGB32FragmentShader, &rgbFragmentShader, &failure))
    {
        if (rgbVertexShader != 0)
        {
            glDeleteShader(rgbVertexShader);
        }
        *details = failure;
        cleanup();
        return false;
    }

    GLuint rgbProgram = glCreateProgram();
    glAttachShader(rgbProgram, rgbVertexShader);
    glAttachShader(rgbProgram, rgbFragmentShader);
    glLinkProgram(rgbProgram);
    glDeleteShader(rgbVertexShader);
    glDeleteShader(rgbFragmentShader);
    glGetProgramiv(rgbProgram, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE)
    {
        *details = "RGB32 program link failed: " + GetProgramLog(rgbProgram);
        glDeleteProgram(rgbProgram);
        cleanup();
        return false;
    }

    constexpr GLfloat kFloatData[]  = {9.0f, 9.0f, 9.0f, 0.25f, 0.5f, 0.75f};
    constexpr GLint kIntData[]      = {9, 9, 9, 2, -3, 4};
    constexpr GLuint kUintData[]    = {9, 9, 9, 5, 6, 7};
    const GLenum rgbFormats[]       = {GL_RGB32F, GL_RGB32I, GL_RGB32UI};
    const void *rgbData[]           = {kFloatData, kIntData, kUintData};
    const GLsizeiptr rgbDataSizes[] = {sizeof(kFloatData), sizeof(kIntData), sizeof(kUintData)};
    const char *rgbUniforms[]       = {"floatValues", "intValues", "uintValues"};
    GLuint rgbBuffers[3]            = {};
    GLuint rgbTextures[3]           = {};
    glGenBuffers(3, rgbBuffers);
    glGenTextures(3, rgbTextures);
    glUseProgram(rgbProgram);
    for (size_t index = 0; index < 3; ++index)
    {
        glBindBuffer(GL_TEXTURE_BUFFER, rgbBuffers[index]);
        glBufferData(GL_TEXTURE_BUFFER, rgbDataSizes[index], rgbData[index], GL_DYNAMIC_DRAW);
        glActiveTexture(GL_TEXTURE0 + static_cast<GLenum>(index));
        glBindTexture(GL_TEXTURE_BUFFER, rgbTextures[index]);
        glTexBuffer(GL_TEXTURE_BUFFER, rgbFormats[index], rgbBuffers[index]);
        glUniform1i(glGetUniformLocation(rgbProgram, rgbUniforms[index]),
                    static_cast<GLint>(index));
    }

    auto cleanupRGB = [&]() {
        glDeleteTextures(3, rgbTextures);
        glDeleteBuffers(3, rgbBuffers);
        glDeleteProgram(rgbProgram);
    };
    auto drawRGBAndCheck = [&](GLubyte red, GLubyte green, GLubyte blue, const char *phase) {
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glFinish();
        GLubyte rgbPixel[4] = {};
        glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, rgbPixel);
        return CheckGLError(phase, &failure) &&
               CheckPixel(rgbPixel, red, green, blue, phase, &failure);
    };

    if (!drawRGBAndCheck(0, 255, 0, "initial RGB32 texture-buffer draw"))
    {
        *details = failure;
        cleanupRGB();
        cleanup();
        return false;
    }

    constexpr GLfloat kFloatSubData[] = {1.25f, 1.5f, 1.75f};
    constexpr GLint kIntSubData[]     = {12, -13, 14};
    constexpr GLuint kUintSubData[]   = {15, 16, 17};
    const void *subData[]             = {kFloatSubData, kIntSubData, kUintSubData};
    const GLsizeiptr subDataSizes[]   = {sizeof(kFloatSubData), sizeof(kIntSubData),
                                         sizeof(kUintSubData)};
    for (size_t index = 0; index < 3; ++index)
    {
        glBindBuffer(GL_TEXTURE_BUFFER, rgbBuffers[index]);
        glBufferSubData(GL_TEXTURE_BUFFER, 12, subDataSizes[index], subData[index]);
    }
    if (!CheckGLError("RGB32 glBufferSubData", &failure) ||
        !drawRGBAndCheck(0, 0, 255, "updated RGB32 texture-buffer draw"))
    {
        *details = failure;
        cleanupRGB();
        cleanup();
        return false;
    }

    constexpr GLfloat kFloatMapped[]   = {2.25f, 2.5f, 2.75f};
    constexpr GLint kIntMapped[]       = {22, -23, 24};
    constexpr GLuint kUintMapped[]     = {25, 26, 27};
    const void *mappedData[]           = {kFloatMapped, kIntMapped, kUintMapped};
    const GLsizeiptr mappedDataSizes[] = {sizeof(kFloatMapped), sizeof(kIntMapped),
                                          sizeof(kUintMapped)};
    for (size_t index = 0; index < 3; ++index)
    {
        glBindBuffer(GL_TEXTURE_BUFFER, rgbBuffers[index]);
        void *mapped =
            glMapBufferRange(GL_TEXTURE_BUFFER, 12, mappedDataSizes[index], GL_MAP_WRITE_BIT);
        if (mapped == nullptr)
        {
            *details = "RGB32 glMapBufferRange returned null";
            cleanupRGB();
            cleanup();
            return false;
        }
        std::memcpy(mapped, mappedData[index], static_cast<size_t>(mappedDataSizes[index]));
        if (glUnmapBuffer(GL_TEXTURE_BUFFER) != GL_TRUE)
        {
            *details = "RGB32 glUnmapBuffer returned GL_FALSE";
            cleanupRGB();
            cleanup();
            return false;
        }
    }
    if (!CheckGLError("RGB32 mapped update", &failure) ||
        !drawRGBAndCheck(255, 0, 0, "mapped RGB32 texture-buffer draw"))
    {
        *details = failure;
        cleanupRGB();
        cleanup();
        return false;
    }

    constexpr GLfloat kFloatReallocated[] = {9.0f, 9.0f, 9.0f, 3.25f, 3.5f, 3.75f};
    constexpr GLint kIntReallocated[]     = {9, 9, 9, 32, -33, 34};
    constexpr GLuint kUintReallocated[]   = {9, 9, 9, 35, 36, 37};
    const void *reallocatedData[]         = {kFloatReallocated, kIntReallocated, kUintReallocated};
    const GLsizeiptr reallocatedDataSizes[] = {sizeof(kFloatReallocated), sizeof(kIntReallocated),
                                               sizeof(kUintReallocated)};
    for (size_t index = 0; index < 3; ++index)
    {
        glBindBuffer(GL_TEXTURE_BUFFER, rgbBuffers[index]);
        glBufferData(GL_TEXTURE_BUFFER, reallocatedDataSizes[index], reallocatedData[index],
                     GL_DYNAMIC_DRAW);
    }
    if (!CheckGLError("RGB32 glBufferData reallocation", &failure) ||
        !drawRGBAndCheck(255, 255, 0, "reallocated RGB32 texture-buffer draw"))
    {
        *details = failure;
        cleanupRGB();
        cleanup();
        return false;
    }

    cleanupRGB();

    const char *version  = reinterpret_cast<const char *>(glGetString(GL_VERSION));
    const char *renderer = reinterpret_cast<const char *>(glGetString(GL_RENDERER));
    const char *shadingLanguage =
        reinterpret_cast<const char *>(glGetString(GL_SHADING_LANGUAGE_VERSION));
    std::ostringstream result;
    result << "EGL " << eglMajor << "." << eglMinor << "\n"
           << "GL_VERSION=" << (version != nullptr ? version : "<null>") << "\n"
           << "GL_RENDERER=" << (renderer != nullptr ? renderer : "<null>") << "\n"
           << "GLSL=" << (shadingLanguage != nullptr ? shadingLanguage : "<null>");
    *details = result.str();

    cleanup();
    return true;
}

void SaveResult(bool passed, const std::string &details)
{
    NSString *documents =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *resultPath = [documents stringByAppendingPathComponent:@"angle-simulator-smoke.txt"];
    NSString *result =
        [NSString stringWithFormat:@"%s\n%s\n", passed ? "PASS" : "FAIL", details.c_str()];
    NSError *error = nil;
    if (![result writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:&error])
    {
        NSLog(@"ANGLE_SIMULATOR_SMOKE unable to save result: %@", error);
    }
}

}  // namespace

@interface AngleSmokeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UILabel *statusLabel;
@end

@implementation AngleSmokeDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    (void)application;
    (void)launchOptions;

    self.window                     = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller    = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;

    self.statusLabel                                           = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.numberOfLines                             = 0;
    self.statusLabel.textAlignment                             = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightSemibold];
    self.statusLabel.text = @"Running ANGLE texture-buffer smoke test…";
    self.statusLabel.accessibilityIdentifier = @"angle-smoke-status";
    [controller.view addSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor
                                                       constant:24],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor
                                                        constant:-24],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
    ]];

    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];

    dispatch_async(dispatch_get_main_queue(), ^{
      std::string validationDetails;
      std::string noErrorDetails;
      const bool validationPassed = RunANGLETextureBufferSmoke(
          /*noErrorContext=*/false, &validationDetails);
      const bool noErrorPassed =
          RunANGLETextureBufferSmoke(/*noErrorContext=*/true, &noErrorDetails);
      const bool passed = validationPassed && noErrorPassed;
      std::ostringstream combinedDetails;
      combinedDetails << "Validation context: " << (validationPassed ? "PASS" : "FAIL") << "\n"
                      << validationDetails << "\n\n"
                      << "No-error context: " << (noErrorPassed ? "PASS" : "FAIL") << "\n"
                      << noErrorDetails;
      const std::string details = combinedDetails.str();
      SaveResult(passed, details);
      NSLog(@"ANGLE_SIMULATOR_SMOKE %s\n%s", passed ? "PASS" : "FAIL", details.c_str());
      self.statusLabel.text =
          [NSString stringWithFormat:@"%s\n\n%s", passed ? "PASS" : "FAIL", details.c_str()];
      self.statusLabel.textColor = passed ? UIColor.systemGreenColor : UIColor.systemRedColor;
      self.statusLabel.accessibilityValue = passed ? @"PASS" : @"FAIL";
    });

    return YES;
}

@end

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AngleSmokeDelegate.class));
    }
}
