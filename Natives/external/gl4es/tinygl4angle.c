#import <Foundation/Foundation.h>
#include <ctype.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define GL_GLEXT_PROTOTYPES

#include "GL/gl.h"
#include "GL/glext.h"
//#include "GLES3/gl32.h"
#include "string_utils.h"

#define LOOKUP_FUNC(func) \
    if (!gles_##func) { \
        gles_##func = dlsym(RTLD_NEXT, #func); \
    } if (!gles_##func) { \
        gles_##func = dlsym(RTLD_DEFAULT, #func); \
    }

#define AliasDecl(NAME, EXT) \
    asm(".global _"# NAME "\n_" #NAME ": b _" #NAME #EXT);

#define AliasDeclPriv(NAME) \
    asm(".global _gl"# NAME "\n_gl" #NAME ": b _GL_" #NAME);

// Core OpenGL 2.0
AliasDecl(glGetTexImage, ANGLE)
AliasDecl(glMapBuffer, OES)

// GL_KHR_debug
AliasDecl(glDebugMessageCallback, KHR)
AliasDecl(glDebugMessageControl, KHR)
AliasDecl(glDebugMessageInsert, KHR)
AliasDecl(glGetDebugMessageLog, KHR)
AliasDecl(glGetObjectLabel, KHR)
AliasDecl(glObjectLabel, KHR)
AliasDecl(glPopDebugGroup, KHR)
AliasDecl(glPushDebugGroup, KHR)

// GL_EXT_blend_func_extended
AliasDecl(glBindFragDataLocation, EXT)
AliasDecl(glBindFragDataLocationIndexed, EXT)

// Hidden functions
AliasDeclPriv(DrawBuffer)
AliasDeclPriv(PolygonMode)

int proxy_width, proxy_height, proxy_intformat, maxTextureSize;

void(*gles_glCopyTexSubImage2D)(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width, GLsizei height);
void(*gles_glCompileShader)(GLuint shader);
//void glGetBufferParameteriv(GLenum target, GLenum value, GLint * data);
void(*gles_glGetAttachedShaders)(GLuint program, GLsizei maxCount, GLsizei *count, GLuint *shaders);
GLenum(*gles_glGetError)(void);
void(*gles_glGetProgramInfoLog)(GLuint program, GLsizei maxLength, GLsizei *length, GLchar *infoLog);
void(*gles_glGetProgramiv)(GLuint program, GLenum pname, GLint *params);
void(*gles_glGetShaderInfoLog)(GLuint shader, GLsizei maxLength, GLsizei *length, GLchar *infoLog);
void(*gles_glGetShaderiv)(GLuint shader, GLenum pname, GLint *params);
void(*gles_glGetTexLevelParameteriv)(GLenum target, GLint level, GLenum pname, GLint *params);
void(*gles_glGetTranslatedShaderSourceANGLE)(GLuint shader, GLsizei bufsize, GLsizei *length, GLchar *source);
void(*gles_glLinkProgram)(GLuint program);
void(*gles_glShaderSource)(GLuint shader, GLsizei count, const GLchar * const *string, const GLint *length);
void(*gles_glTexImage2D)(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const GLvoid *data);
void(*gles_glTexSubImage2D)(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const GLvoid *data);
void(*gles_glTexParameterfv)(GLenum target, GLenum pname, const GLfloat *params);

#ifndef GL_TRANSLATED_SHADER_SOURCE_LENGTH_ANGLE
#define GL_TRANSLATED_SHADER_SOURCE_LENGTH_ANGLE 0x93A0
#endif
#ifndef GL_DEBUG_OUTPUT_KHR
#define GL_DEBUG_OUTPUT_KHR 0x92E0
#endif
#ifndef GL_DEBUG_OUTPUT_SYNCHRONOUS_KHR
#define GL_DEBUG_OUTPUT_SYNCHRONOUS_KHR 0x8242
#endif

typedef void (*AmethystGLDebugProc)(
    GLenum source,
    GLenum type,
    GLuint id,
    GLenum severity,
    GLsizei length,
    const GLchar *message,
    const void *userParam);

typedef struct ShaderDiagnosticRecord {
    GLuint shader;
    unsigned sequence;
    struct ShaderDiagnosticRecord *next;
} ShaderDiagnosticRecord;

static pthread_once_t diagnosticsInitOnce = PTHREAD_ONCE_INIT;
static pthread_once_t diagnosticsContextOnce = PTHREAD_ONCE_INIT;
static pthread_mutex_t diagnosticsLock = PTHREAD_MUTEX_INITIALIZER;
static ShaderDiagnosticRecord *diagnosticShaders;
static unsigned diagnosticSequence;
static unsigned diagnosticLogSequence;
static int diagnosticsEnabled;
static char diagnosticsDirectory[PATH_MAX];

static void diagnostics_init(void) {
    const char *setting = getenv("AMETHYST_GL_DIAGNOSTICS");
    if (!setting || !setting[0] || !strcmp(setting, "0")) return;

    const char *home = getenv("POJAV_HOME");
    if (!home || !home[0]) return;

    char label[64] = {0};
    size_t outputIndex = 0;
    for (size_t inputIndex = 0;
            setting[inputIndex] && outputIndex < sizeof(label) - 1;
            inputIndex++) {
        unsigned char character = setting[inputIndex];
        label[outputIndex++] = (isalnum(character) ||
            character == '-' || character == '_') ? character : '_';
    }
    if (!label[0]) strcpy(label, "run");

    char logsDirectory[PATH_MAX];
    char baseDirectory[PATH_MAX];
    if (snprintf(logsDirectory, sizeof(logsDirectory), "%s/logs", home) >=
            sizeof(logsDirectory) ||
        snprintf(baseDirectory, sizeof(baseDirectory),
            "%s/angle-diagnostics", logsDirectory) >= sizeof(baseDirectory) ||
        snprintf(diagnosticsDirectory, sizeof(diagnosticsDirectory),
            "%s/%s-%d", baseDirectory, label, getpid()) >=
            sizeof(diagnosticsDirectory)) {
        diagnosticsDirectory[0] = '\0';
        return;
    }

    mkdir(logsDirectory, 0755);
    mkdir(baseDirectory, 0755);
    if (mkdir(diagnosticsDirectory, 0755) != 0 && errno != EEXIST) {
        diagnosticsDirectory[0] = '\0';
        return;
    }
    diagnosticsEnabled = 1;
    fprintf(stderr, "[tinygl4angle] diagnostics: %s\n",
        diagnosticsDirectory);
    fflush(stderr);
}

static int diagnostics_enabled(void) {
    pthread_once(&diagnosticsInitOnce, diagnostics_init);
    return diagnosticsEnabled;
}

static void diagnostics_log(const char *format, ...) {
    if (!diagnostics_enabled()) return;

    pthread_mutex_lock(&diagnosticsLock);
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/diagnostics.log",
        diagnosticsDirectory);
    FILE *file = fopen(path, "a");
    unsigned sequence = ++diagnosticLogSequence;

    va_list args;
    va_start(args, format);
    if (file) {
        fprintf(file, "[%06u] ", sequence);
        vfprintf(file, format, args);
        fputc('\n', file);
        fclose(file);
    }
    va_end(args);

    va_start(args, format);
    fprintf(stderr, "[tinygl4angle:%06u] ", sequence);
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    fflush(stderr);
    va_end(args);
    pthread_mutex_unlock(&diagnosticsLock);
}

static void diagnostics_write(
        const char *filename,
        const void *contents,
        size_t length) {
    if (!diagnostics_enabled()) return;

    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/%s",
            diagnosticsDirectory, filename) >= sizeof(path)) {
        return;
    }
    FILE *file = fopen(path, "wb");
    if (!file) {
        diagnostics_log("could not write %s", path);
        return;
    }
    fwrite(contents, 1, length, file);
    fclose(file);
}

static unsigned diagnostics_record_shader(
        GLuint shader,
        const char *rawSource,
        const char *convertedSource) {
    if (!diagnostics_enabled()) return 0;

    pthread_mutex_lock(&diagnosticsLock);
    ShaderDiagnosticRecord *record = diagnosticShaders;
    while (record && record->shader != shader) record = record->next;
    if (!record) {
        record = calloc(1, sizeof(*record));
        if (record) {
            record->shader = shader;
            record->next = diagnosticShaders;
            diagnosticShaders = record;
        }
    }
    unsigned sequence = ++diagnosticSequence;
    if (record) record->sequence = sequence;
    pthread_mutex_unlock(&diagnosticsLock);

    char filename[128];
    snprintf(filename, sizeof(filename), "shader-%u-%06u-raw.glsl",
        shader, sequence);
    diagnostics_write(filename, rawSource, strlen(rawSource));
    snprintf(filename, sizeof(filename), "shader-%u-%06u-converted.glsl",
        shader, sequence);
    diagnostics_write(filename, convertedSource, strlen(convertedSource));
    diagnostics_log(
        "shader %u source %u: raw=%zu bytes, converted=%zu bytes",
        shader, sequence, strlen(rawSource), strlen(convertedSource));
    return sequence;
}

static unsigned diagnostics_shader_sequence(GLuint shader) {
    unsigned sequence = 0;
    pthread_mutex_lock(&diagnosticsLock);
    ShaderDiagnosticRecord *record = diagnosticShaders;
    while (record && record->shader != shader) record = record->next;
    if (record) sequence = record->sequence;
    pthread_mutex_unlock(&diagnosticsLock);
    return sequence;
}

static const char *diagnostics_string(
        const GLubyte *(*getString)(GLenum),
        GLenum name) {
    const GLubyte *value = getString ? getString(name) : NULL;
    return value ? (const char *)value : "(null)";
}

static void diagnostics_debug_callback(
        GLenum source,
        GLenum type,
        GLuint id,
        GLenum severity,
        GLsizei length,
        const GLchar *message,
        const void *userParam) {
    (void)userParam;
    diagnostics_log(
        "KHR_debug source=0x%x type=0x%x id=%u severity=0x%x: %.*s",
        source, type, id, severity, length, message ? message : "");
}

static void diagnostics_capture_context(void) {
    if (!diagnostics_enabled()) return;

    const GLubyte *(*getString)(GLenum) =
        dlsym(RTLD_NEXT, "glGetString");
    const GLubyte *(*getStringi)(GLenum, GLuint) =
        dlsym(RTLD_NEXT, "glGetStringi");
    void(*getIntegerv)(GLenum, GLint *) =
        dlsym(RTLD_NEXT, "glGetIntegerv");
    void(*debugCallback)(AmethystGLDebugProc, const void *) =
        dlsym(RTLD_NEXT, "glDebugMessageCallbackKHR");
    void(*debugControl)(GLenum, GLenum, GLenum, GLsizei,
        const GLuint *, GLboolean) =
        dlsym(RTLD_NEXT, "glDebugMessageControlKHR");
    void(*enable)(GLenum) = dlsym(RTLD_NEXT, "glEnable");

    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/context.txt", diagnosticsDirectory);
    FILE *file = fopen(path, "w");
    if (file) {
        fprintf(file, "vendor=%s\n", diagnostics_string(getString, GL_VENDOR));
        fprintf(file, "renderer=%s\n",
            diagnostics_string(getString, GL_RENDERER));
        fprintf(file, "version=%s\n",
            diagnostics_string(getString, GL_VERSION));
        fprintf(file, "shading_language=%s\n",
            diagnostics_string(getString, GL_SHADING_LANGUAGE_VERSION));

        GLint major = 0;
        GLint minor = 0;
        GLint extensionCount = 0;
        if (getIntegerv) {
            getIntegerv(GL_MAJOR_VERSION, &major);
            getIntegerv(GL_MINOR_VERSION, &minor);
            getIntegerv(GL_NUM_EXTENSIONS, &extensionCount);
        }
        fprintf(file, "major=%d\nminor=%d\nextension_count=%d\n",
            major, minor, extensionCount);
        if (getStringi && extensionCount > 0) {
            for (GLint index = 0; index < extensionCount; index++) {
                const GLubyte *extension =
                    getStringi(GL_EXTENSIONS, (GLuint)index);
                if (extension) fprintf(file, "extension=%s\n", extension);
            }
        } else {
            fprintf(file, "extensions=%s\n",
                diagnostics_string(getString, GL_EXTENSIONS));
        }
        fclose(file);
    }

    diagnostics_log("GL vendor=%s renderer=%s version=%s GLSL=%s",
        diagnostics_string(getString, GL_VENDOR),
        diagnostics_string(getString, GL_RENDERER),
        diagnostics_string(getString, GL_VERSION),
        diagnostics_string(getString, GL_SHADING_LANGUAGE_VERSION));

    if (debugCallback && debugControl && enable) {
        enable(GL_DEBUG_OUTPUT_KHR);
        enable(GL_DEBUG_OUTPUT_SYNCHRONOUS_KHR);
        debugControl(GL_DONT_CARE, GL_DONT_CARE, GL_DONT_CARE,
            0, NULL, GL_TRUE);
        debugCallback(diagnostics_debug_callback, NULL);
        diagnostics_log("GL_KHR_debug callback installed");
    } else {
        diagnostics_log("GL_KHR_debug callback unavailable");
    }
}

static void diagnostics_prepare_context(void) {
    if (diagnostics_enabled()) {
        pthread_once(&diagnosticsContextOnce, diagnostics_capture_context);
    }
}

void glClearDepth(GLdouble depth) {
    glClearDepthf(depth);
}

void glShaderSource(GLuint shader, GLsizei count, const GLchar * const *string, const GLint *length) {
    LOOKUP_FUNC(glShaderSource)

    // DBG(printf("glShaderSource(%d, %d, %p, %p)\n", shader, count, string, length);)
    char *source = NULL;
    char *converted;

    // get the size of the shader sources and than concatenate in a single string
    int l = 0;
    for (int i=0; i<count; i++) l+=(length && length[i] >= 0)?length[i]:strlen(string[i]);
    if (source) free(source);
    source = calloc(1, l+1);
    if(length) {
        for (int i=0; i<count; i++) {
            if(length[i] >= 0)
                strncat(source, string[i], length[i]);
            else
                strcat(source, string[i]);
        }
    } else {
        for (int i=0; i<count; i++)
            strcat(source, string[i]);
    }
    
    char *source2 = strchr(source, '#');
    if (!source2) {
        source2 = source;
    }
    // are there #version?
    if (!strncmp(source2, "#version ", 9)) {
        if (!strncmp(&source2[13], "es", 2)) {
            // This is for gl4es. TODO: maybe remove 'es' aswell?
            return;
        }
        converted = strdup(source2);
        if (converted[9] == '1') {
            if (converted[10] - '0' < 2) {
                // 100, 110 -> 120
                //converted[10] = '2';
            } else if (converted[10] - '0' < 6) {
                // 130, 140, 150 -> 330
                converted[9] = converted[10] = '3';
            }
        }
        // remove "core", is it safe?
        if (!strncmp(&converted[13], "core", 4)) {
            strncpy(&converted[13], "\n//c", 4);
        }
    } else {
        converted = calloc(1, strlen(source) + 13);
        strcpy(converted, "#version 120\n");
        strcpy(&converted[13], strdup(source));
    }

    int convertedLen = strlen(converted);

#ifdef __APPLE__
    // patch OptiFine 1.17.x
    if (FindString(converted, "\nuniform mat4 textureMatrix = mat4(1.0);")) {
        InplaceReplace(converted, &convertedLen, "\nuniform mat4 textureMatrix = mat4(1.0);", "\n#define textureMatrix mat4(1.0)");
    }
#endif

    // Workaround unassigned outputs: use gl_FragData[] instead of separate color outputs
    char tmpOutFindLine[20];
    char tmpOutReplaceLine[33];
    strncpy(tmpOutFindLine, "out vec4 outColor0;", 20);
    strncpy(tmpOutReplaceLine, "#define outColor0 gl_FragData[0]", 33);
    for (int i = 0; i < 8; i++) {
        tmpOutFindLine[17] = '0'+i;
        if (FindString(converted, tmpOutFindLine)) {
            tmpOutReplaceLine[16] = '0'+i;
            tmpOutReplaceLine[30] = '0'+i;
            converted = InplaceReplace(converted, &convertedLen, tmpOutFindLine, tmpOutReplaceLine);
        }
    }

    // some needed exts
    const char* extensions =
        "#extension GL_EXT_blend_func_extended : enable\n"
        "#extension GL_EXT_draw_buffers : enable\n"
        // For OptiFine (see patch above)
        "#extension GL_EXT_shader_non_constant_global_initializers : enable\n";
    converted = InplaceInsert(GetLine(converted, 1), extensions, converted, &convertedLen);

    diagnostics_prepare_context();
    diagnostics_record_shader(shader, source, converted);

    gles_glShaderSource(shader, 1, (const GLchar * const*)((converted)?(&converted):(&source)), NULL);

    free(source);
    free(converted);
}

void glCompileShader(GLuint shader) {
    LOOKUP_FUNC(glCompileShader)
    if (!gles_glCompileShader) return;
    if (!diagnostics_enabled()) {
        gles_glCompileShader(shader);
        return;
    }

    LOOKUP_FUNC(glGetShaderiv)
    LOOKUP_FUNC(glGetShaderInfoLog)
    if (!gles_glGetShaderiv || !gles_glGetShaderInfoLog) {
        diagnostics_log("shader %u: required compile entry point missing",
            shader);
        gles_glCompileShader(shader);
        return;
    }

    diagnostics_prepare_context();
    gles_glCompileShader(shader);

    GLint status = GL_FALSE;
    GLint shaderType = 0;
    GLint infoLength = 0;
    gles_glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    gles_glGetShaderiv(shader, GL_SHADER_TYPE, &shaderType);
    gles_glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &infoLength);
    unsigned sequence = diagnostics_shader_sequence(shader);

    if (infoLength > 1) {
        char *info = calloc(1, (size_t)infoLength);
        if (info) {
            GLsizei written = 0;
            gles_glGetShaderInfoLog(shader, infoLength, &written, info);
            char filename[128];
            snprintf(filename, sizeof(filename),
                "shader-%u-%06u-compile.log", shader, sequence);
            diagnostics_write(filename, info, (size_t)written);
            diagnostics_log(
                "shader %u source %u type=0x%x compile=%s: %.*s",
                shader, sequence, shaderType,
                status == GL_TRUE ? "ok" : "FAILED",
                written, info);
            free(info);
        }
    } else {
        diagnostics_log("shader %u source %u type=0x%x compile=%s",
            shader, sequence, shaderType,
            status == GL_TRUE ? "ok" : "FAILED");
    }

    LOOKUP_FUNC(glGetTranslatedShaderSourceANGLE)
    if (gles_glGetTranslatedShaderSourceANGLE) {
        GLint translatedLength = 0;
        gles_glGetShaderiv(shader,
            GL_TRANSLATED_SHADER_SOURCE_LENGTH_ANGLE,
            &translatedLength);
        if (translatedLength > 1) {
            char *translated = calloc(1, (size_t)translatedLength);
            if (translated) {
                GLsizei written = 0;
                gles_glGetTranslatedShaderSourceANGLE(
                    shader, translatedLength, &written, translated);
                char filename[128];
                snprintf(filename, sizeof(filename),
                    "shader-%u-%06u-angle-translated.glsl",
                    shader, sequence);
                diagnostics_write(filename, translated, (size_t)written);
                free(translated);
            }
        }
    }
}

void glLinkProgram(GLuint program) {
    LOOKUP_FUNC(glLinkProgram)
    if (!gles_glLinkProgram) return;
    if (!diagnostics_enabled()) {
        gles_glLinkProgram(program);
        return;
    }

    LOOKUP_FUNC(glGetProgramiv)
    LOOKUP_FUNC(glGetProgramInfoLog)
    if (!gles_glGetProgramiv || !gles_glGetProgramInfoLog) {
        diagnostics_log("program %u: required link entry point missing",
            program);
        gles_glLinkProgram(program);
        return;
    }

    diagnostics_prepare_context();
    gles_glLinkProgram(program);

    GLint status = GL_FALSE;
    GLint infoLength = 0;
    GLint attachedCount = 0;
    gles_glGetProgramiv(program, GL_LINK_STATUS, &status);
    gles_glGetProgramiv(program, GL_INFO_LOG_LENGTH, &infoLength);
    gles_glGetProgramiv(program, GL_ATTACHED_SHADERS, &attachedCount);

    char attached[512] = {0};
    if (attachedCount > 0) {
        LOOKUP_FUNC(glGetAttachedShaders)
        if (gles_glGetAttachedShaders) {
            GLuint *shaders = calloc((size_t)attachedCount, sizeof(GLuint));
            if (shaders) {
                GLsizei actualCount = 0;
                gles_glGetAttachedShaders(
                    program, attachedCount, &actualCount, shaders);
                size_t offset = 0;
                for (GLsizei index = 0; index < actualCount &&
                        offset < sizeof(attached); index++) {
                    offset += snprintf(attached + offset,
                        sizeof(attached) - offset,
                        "%s%u(source %u)",
                        index ? "," : "",
                        shaders[index],
                        diagnostics_shader_sequence(shaders[index]));
                }
                free(shaders);
            }
        }
    }

    if (infoLength > 1) {
        char *info = calloc(1, (size_t)infoLength);
        if (info) {
            GLsizei written = 0;
            gles_glGetProgramInfoLog(program, infoLength, &written, info);
            char filename[128];
            snprintf(filename, sizeof(filename),
                "program-%u-link.log", program);
            diagnostics_write(filename, info, (size_t)written);
            diagnostics_log(
                "program %u shaders=[%s] link=%s: %.*s",
                program, attached,
                status == GL_TRUE ? "ok" : "FAILED",
                written, info);
            free(info);
        }
    } else {
        diagnostics_log("program %u shaders=[%s] link=%s",
            program, attached,
            status == GL_TRUE ? "ok" : "FAILED");
    }
}

GLenum glGetError(void) {
    LOOKUP_FUNC(glGetError)
    if (!gles_glGetError) return GL_INVALID_OPERATION;
    GLenum error = gles_glGetError();
    if (error != GL_NO_ERROR && diagnostics_enabled()) {
        void *returnAddress = __builtin_return_address(0);
        Dl_info info = {0};
        if (dladdr(returnAddress, &info) && info.dli_sname) {
            diagnostics_log(
                "glGetError observed first-party error=0x%x caller=%s+0x%lx",
                error, info.dli_sname,
                (unsigned long)((uintptr_t)returnAddress -
                    (uintptr_t)info.dli_saddr));
        } else {
            diagnostics_log(
                "glGetError observed first-party error=0x%x caller=%p",
                error, returnAddress);
        }
    }
    return error;
}

int isProxyTexture(GLenum target) {
    switch (target) {
        case GL_PROXY_TEXTURE_1D:
        case GL_PROXY_TEXTURE_2D:
        case GL_PROXY_TEXTURE_3D:
        case GL_PROXY_TEXTURE_RECTANGLE_ARB:
            return 1;
    }
    return 0;
}

static int inline nlevel(int size, int level) {
    if(size) {
        size>>=level;
        if(!size) size=1;
    }
    return size;
}

void glGetTexLevelParameteriv(GLenum target, GLint level, GLenum pname, GLint *params) {
    LOOKUP_FUNC(glGetTexLevelParameteriv)
    // NSLog("glGetTexLevelParameteriv(%x, %d, %x, %p)", target, level, pname, params);
    if (isProxyTexture(target)) {
        switch (pname) {
            case GL_TEXTURE_WIDTH:
                (*params) = nlevel(proxy_width,level);
                break;
            case GL_TEXTURE_HEIGHT: 
                (*params) = nlevel(proxy_height,level);
                break;
            case GL_TEXTURE_INTERNAL_FORMAT:
                (*params) = proxy_intformat;
                break;
        }
    } else {
        gles_glGetTexLevelParameteriv(target, level, pname, params);
    }
}

void glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const GLvoid *data) {
    LOOKUP_FUNC(glTexImage2D)

    if (type == GL_UNSIGNED_INT_8_8_8_8_REV) {
        type = GL_UNSIGNED_BYTE;
    }

    if (isProxyTexture(target)) {
        if (!maxTextureSize) {
            glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTextureSize);
            // maxTextureSize = 16384;
            // NSLog(@"Maximum texture size: %d", maxTextureSize);
        }
        proxy_width = ((width<<level)>maxTextureSize)?0:width;
        proxy_height = ((height<<level)>maxTextureSize)?0:height;
        proxy_intformat = internalformat;
        // swizzle_internalformat((GLenum *) &internalformat, format, type);
    } else {
        gles_glTexImage2D(target, level, internalformat, width, height, border, format, type, data);
    }
}


void glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const GLvoid *data) {
    LOOKUP_FUNC(glTexSubImage2D)
    if (type == GL_UNSIGNED_INT_8_8_8_8_REV) {
        type = GL_UNSIGNED_BYTE;
    }
    gles_glTexSubImage2D(target, level, xoffset, yoffset, width, height, format, type, data);
}


void glTexParameterfv(GLenum target, GLenum pname, const GLfloat *params) {
    LOOKUP_FUNC(glTexParameterfv)
    if (pname != GL_TEXTURE_LOD_BIAS) {
        gles_glTexParameterfv(target, pname, params);
    }
}
void glTexParameterf(GLenum target, GLenum pname, GLfloat param) {
    glTexParameterfv(target, pname, &param);
}

// Handle reading depth buffer
void glReadBuffer(GLenum mode) {
    // Override with stub
}

void glCopyTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width, GLsizei height) {
    if (target != GL_TEXTURE_2D) {
        LOOKUP_FUNC(glCopyTexSubImage2D)
        gles_glCopyTexSubImage2D(target, level, xoffset, yoffset, x, y, width, height);
    }

    // Override with stub
#if 0
    float *pixels = malloc(width*height*sizeof(float));
    for (int i = 0; i < width*height; i++) {
        pixels[i] = 0.5f;
    }
    glTexSubImage2D(target, level, xoffset, yoffset, width, height, GL_DEPTH_COMPONENT, GL_FLOAT, pixels);
    free(pixels);
#endif

#if 0
    static GLuint depthFB;
    if (!depthFB) {
        glGenFramebuffers(1, &depthFB);
    }
    int fbID, texID;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &fbID);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &texID);
    //glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, depthFB);
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, target, texID, level);
    assert(glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
    glBlitFramebuffer(xoffset, yoffset, width, height, x, y, width, height, GL_DEPTH_BUFFER_BIT, GL_NEAREST);
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, target, 0, level);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbID);
#endif
}

// VertexArray stuff
#define THUNK(suffix, type, M2) \
void  glVertexAttrib1##suffix (GLuint index, type v0) { GLfloat f[4] = {0,0,0,1}; f[0] =v0; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib2##suffix (GLuint index, type v0, type v1) { GLfloat f[4] = {0,0,0,1}; f[0] =v0; f[1]=v1; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib3##suffix (GLuint index, type v0, type v1, type v2) { GLfloat f[4] = {0,0,0,1}; f[0] =v0; f[1]=v1; f[2]=v2; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib4##suffix (GLuint index, type v0, type v1, type v2, type v3) { GLfloat f[4] = {0,0,0,1}; f[0] =v0; f[1]=v1; f[2]=v2; f[3]=v3; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib1##suffix##v (GLuint index, const type *v) { GLfloat f[4] = {0,0,0,1}; f[0] =v[0]; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib2##suffix##v (GLuint index, const type *v) { GLfloat f[4] = {0,0,0,1}; f[0] =v[0]; f[1]=v[1]; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib3##suffix##v (GLuint index, const type *v) { GLfloat f[4] = {0,0,0,1}; f[0] =v[0]; f[1]=v[1]; f[2]=v[2]; glVertexAttrib4fv(index, f); };
THUNK(s, GLshort, );
THUNK(d, GLdouble, _D);
#undef THUNK
void  glVertexAttrib4dv (GLuint index, const GLdouble *v) { GLfloat f[4] = {0,0,0,1}; f[0] =v[0]; f[1]=v[1]; f[2]=v[2]; f[3]=v[3]; glVertexAttrib4fv(index, f); };

#define THUNK(suffix, type, norm) \
void  glVertexAttrib4##suffix##v (GLuint index, const type *v) { GLfloat f[4] = {0,0,0,1}; f[0] =v[0]; f[1]=v[1]; f[2]=v[2]; f[3]=v[3]; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib4N##suffix##v (GLuint index, const type *v) { GLfloat f[4] = {0,0,0,1}; f[0] =v[0]/norm; f[1]=v[1]/norm; f[2]=v[2]/norm; f[3]=v[3]/norm; glVertexAttrib4fv(index, f); };
THUNK(b, GLbyte, 127.0f);
THUNK(ub, GLubyte, 255.0f);
THUNK(s, GLshort, 32767.0f);
THUNK(us, GLushort, 65535.0f);
THUNK(i, GLint, 2147483647.0f);
THUNK(ui, GLuint, 4294967295.0f);
#undef THUNK
void glVertexAttrib4Nub(GLuint index, GLubyte v0, GLubyte v1, GLubyte v2, GLubyte v3) {GLfloat f[4] = {0,0,0,1}; f[0] =v0/255.f; f[1]=v1/255.f; f[2]=v2/255.f; f[3]=v3/255.f; glVertexAttrib4fv(index, f); };
