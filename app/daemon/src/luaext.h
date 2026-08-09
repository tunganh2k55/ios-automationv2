#ifndef IOSAUTO_LUAEXT_H
#define IOSAUTO_LUAEXT_H

// Đăng ký nhóm hàm Lua "mở rộng" (dựa trên Foundation): base64, JSON, HTTP, proxy hệ thống,
// mở URL, thông tin thiết bị/mạng. Gọi 1 lần khi tạo lua_State (từ register_funcs trong lua_bind.c).
struct lua_State;
void luaext_register(struct lua_State *L);

#endif
