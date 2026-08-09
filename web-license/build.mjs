// Build frontend TypeScript (src/) -> public/**/*.js bằng esbuild.
//   node build.mjs           → build 1 lần (dùng cho `npm start`)
//   node build.mjs --watch   → watch + livereload :35729 (dùng cho `npm run dev`)
import * as esbuild from 'esbuild';

const watch = process.argv.includes('--watch');

// Mỗi trang = 1 entry → 1 bundle self-contained (đã gộp src/shared/api.ts).
const entryPoints = [
  'src/User/intro.ts',
  'src/User/auth.ts',
  'src/User/dashboard.ts',
  'src/User/orders.ts',
  'src/User/license.ts',
  'src/User/setting.ts',
  'src/Admin/index.ts',
  'src/Admin/tools.ts',
  'src/Admin/licenses.ts',
  'src/Admin/user.ts',
];

const options = {
  entryPoints,
  outbase: 'src',      // src/User/intro.ts -> public/User/intro.js
  outdir: 'public',
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: 'es2019',
  sourcemap: watch,    // map chỉ sinh khi dev (không commit)
  logLevel: 'info',
};

if (watch) {
  const ctx = await esbuild.context(options);
  await ctx.watch();
  const livereload = (await import('livereload')).default;
  const lr = livereload.createServer({ exts: ['js', 'css', 'html', 'png'], delay: 80 });
  lr.watch('public');
  console.log('👀 esbuild watch + livereload :35729 — sửa .ts/.css/.html là trình duyệt tự reload.');
} else {
  await esbuild.build(options);
  console.log('✅ Build frontend xong.');
}
