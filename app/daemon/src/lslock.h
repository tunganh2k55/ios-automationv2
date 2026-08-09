#ifndef IOSAUTO_LSLOCK_H
#define IOSAUTO_LSLOCK_H

// LaunchServices (LSApplicationWorkspace / LSApplicationProxy) KHÔNG an toàn đa luồng. Daemon gọi LS
// từ NHIỀU luồng: HTTP worker (apps_all/apps → list_json; launch/kill/cleardata) + luồng Lua
// (openUrl, crane.*). Hai lời gọi LS ĐỒNG THỜI → race trong LS/XPC client → daemon chết (SIGKILL,
// không bắt được nên không có backtrace). MỌI truy cập LS phải bọc giữa ia_ls_lock()/ia_ls_unlock()
// — 1 mutex DÙNG CHUNG toàn daemon (không được để mỗi file 1 mutex riêng thì mới thật sự serialize).
void ia_ls_lock(void);
void ia_ls_unlock(void);

#endif
