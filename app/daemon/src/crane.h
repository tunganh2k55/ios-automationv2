#ifndef IOSAUTO_CRANE_H
#define IOSAUTO_CRANE_H

// Đăng ký bảng Lua `crane` (điều khiển tweak Crane của opa334 qua cranectl + craneprefs.plist).
// Gọi 1 lần khi tạo lua_State (từ register_funcs trong lua_bind.c).
struct lua_State;
void crane_register(struct lua_State *L);

#endif
