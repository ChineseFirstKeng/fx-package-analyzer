#ifndef CCLANG_H
#define CCLANG_H

/*
 * libclang 最小 C 声明（布局与 clang-c/Index.h 一致）。
 * 不 #include SDK 头、不链接 —— 运行时 dlopen 当前 Xcode 的 libclang.dylib。
 * 作用：让 Swift 以 C 类型做 @convention(c) 值传递（Swift 自定义结构体做不到）。
 */

typedef struct { const void *data; unsigned private_flags; } CXStringT;
typedef struct { int kind; int xdata; const void *data[3]; } CXCursorT;
typedef struct { int kind; void *data[2]; } CXTypeT;
typedef struct { const void *ptr_data[2]; unsigned int_data; } CXSourceLocationT;

typedef void *CXIndexT;
typedef void *CXTUT;
typedef void *CXFileT;

typedef int (*CXVisitorT)(CXCursorT cursor, CXCursorT parent, void *client_data);

typedef CXIndexT (*fn_createIndex)(int, int);
typedef void (*fn_disposeIndex)(CXIndexT);
typedef CXTUT (*fn_createTU)(CXIndexT, const char *);
typedef void (*fn_disposeTU)(CXTUT);
typedef CXCursorT (*fn_tuCursor)(CXTUT);
typedef unsigned (*fn_visitChildren)(CXCursorT, CXVisitorT, void *);
typedef int (*fn_cursorKind)(CXCursorT);
typedef CXStringT (*fn_cursorSpelling)(CXCursorT);
typedef const char *(*fn_getCString)(CXStringT);
typedef void (*fn_disposeString)(CXStringT);
typedef CXSourceLocationT (*fn_cursorLocation)(CXCursorT);
typedef void (*fn_spellingLocation)(CXSourceLocationT, CXFileT *, unsigned *, unsigned *, unsigned *);
typedef CXStringT (*fn_getFileName)(CXFileT);
typedef CXTypeT (*fn_cursorType)(CXCursorT);
typedef CXTypeT (*fn_canonicalType)(CXTypeT);
typedef CXTypeT (*fn_pointeeType)(CXTypeT);
typedef CXCursorT (*fn_typeDeclaration)(CXTypeT);
typedef CXCursorT (*fn_cursorReferenced)(CXCursorT);
typedef int (*fn_numArguments)(CXCursorT);
typedef CXCursorT (*fn_getArgument)(CXCursorT, unsigned);
typedef CXStringT (*fn_typeSpelling)(CXTypeT);

#endif
