#ifndef IOSAUTO_IMGMATCH_H
#define IOSAUTO_IMGMATCH_H

// Khớp ẢNH MẪU (đã lưu trong thư mục images) trên màn hình hiện tại (chụp fbcap, cùng không
// gian với /api/screenshot). Dùng ZNCC (chuẩn hoá, chịu được đổi độ sáng) + integral image.
//   img_name         : tên file ảnh mẫu (crop_*.jpg…)
//   rx,ry,rw,rh      : vùng giới hạn tìm (ĐIỂM màn); rw<=0||rh<=0 → tìm toàn màn
//   wantIdx          : match thứ mấy (1-based, theo điểm số giảm dần, có non-max suppression)
//   threshold        : ngưỡng ZNCC 0..1 (mặc định nên ~0.8)
//   out_cx,out_cy    : (ra) tâm match theo ĐIỂM màn — dùng để tap
//   out_score        : (ra) điểm ZNCC của match
// Trả 1 nếu tìm được match thứ wantIdx với score>=threshold; 0 nếu không.
int imgmatch_find(const char *img_name, int rx, int ry, int rw, int rh,
                  int wantIdx, double threshold, int *out_cx, int *out_cy, double *out_score);

#endif
