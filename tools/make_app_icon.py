"""把红笔触图标源图的白色背景转为透明，并生成两端所需的各尺寸。

===== 为什么不能只做「白色 -> alpha 0」的阈值抠图 =====
源图是**带抗锯齿**的笔触：笔画边缘存在大量「红白混合」的像素
（例如 (240,180,180) 这种）。若只把纯白判为透明、其余保留，
边缘会留下一圈**白边**，在任何非白底色上都能看见（深色主题下尤其明显）。

正确做法是「从白底反解」：设原像素 C 是前景 F 与白底(255) 的混合，
    C = a·F + (1-a)·255
未知 a 与 F，两个方程解不出三个未知数，因此额外假定**前景是纯色**——
而这张图确实是单色红笔触（实测主色 (215,85,85)）。
于是 a 可由「距离白色的程度」求出：

    a = 1 - min(C) / min(F)      （取通道最小值最稳，红色通道恒为最大）

再反解 F = (C - (1-a)·255) / a，得到不带白边的纯红前景。
a 用逐通道求出的最大值，保证边缘过渡自然。

用法: python tools/make_app_icon.py
"""
import io
import os
import sys

import numpy as np
from PIL import Image

# 源图标路径由命令行给出，**不写死在脚本里**。
#
# 原先这里硬编码了开发者本机的完整路径，含 Windows 用户名、QQ 号与
# QQ 的文件缓存目录 —— 开源后等于把这些一并公布。改成参数之后，
# 脚本本身不含任何个人信息，别人用自己的图也能跑。
def _source_path() -> str:
    if len(sys.argv) < 2:
        raise SystemExit(
            '用法: python tools/make_app_icon.py <原始图标路径>')
    path = sys.argv[1]
    if not os.path.isfile(path):
        raise SystemExit('找不到文件: ' + path)
    return path

# 本脚本位于 <工程>/tools/，因此父目录即 Flutter 工程根。
#
# 早先这里还派生过一个指向同级鸿蒙工程的路径（移植期两端并列开发），
# 但本仓库只有 Flutter 端 —— 留着那段会让脚本在别人机器上试图写一个
# 不存在的目录。
PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 前景纯色。从源图实测得到（见模块文档：反解白边需要知道它）。
FG = np.array([215.0, 85.0, 85.0], dtype=np.float32)

# 内容在方形容器里占的比例。
#
# Android 传统启动图标（非自适应）建议四周各留约 1/6 边距，
# 否则图标会被裁掉或被相邻图标挤在一起；这里取 0.72 视觉上与系统图标一致。
CONTENT_RATIO = 0.72


def white_to_alpha(im: Image.Image) -> Image.Image:
    """白底反解为透明前景（见模块文档的推导）"""
    rgb = np.asarray(im.convert('RGB'), dtype=np.float32)

    # ===== alpha 的推导（这里第一版写反过，实测才发现）=====
    # 混合式：C = a·F + (1-a)·255
    # 取通道最小值：纯前景 min(F)=min(FG)=85 对应 a=1；
    # 纯白 min=255 对应 a=0。两者之间线性：
    #     a = (255 - min(C)) / (255 - min(FG))
    #
    # 反例（第一版的写法 a = 1 - min(C)/min(FG)）会把**完全饱和的红**
    # 算成 a=0 —— 正好把最该保留的笔画主体整片抹掉，只留边缘。
    lo = float(FG.min())
    a = (255.0 - rgb.min(axis=2)) / (255.0 - lo)
    a = np.clip(a, 0.0, 1.0)

    # 反解前景色：F = (C - (1-a)·255) / a，仅在有覆盖的地方计算
    safe = np.maximum(a, 1e-6)[:, :, None]
    fg = (rgb - (1.0 - a[:, :, None]) * 255.0) / safe
    fg = np.clip(fg, 0.0, 255.0)

    out = np.zeros((*rgb.shape[:2], 4), dtype=np.uint8)
    out[:, :, :3] = np.round(fg).astype(np.uint8)
    out[:, :, 3] = np.round(a * 255).astype(np.uint8)
    return Image.fromarray(out, 'RGBA')


def fit_square(im: Image.Image, side: int,
               ratio: float = CONTENT_RATIO) -> Image.Image:
    """等比缩放并居中放进正方形画布（保持宽高比，不拉伸）"""
    w, h = im.size
    target = side * ratio
    scale = min(target / w, target / h)
    nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
    resized = im.resize((nw, nh), Image.LANCZOS)

    canvas = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    canvas.paste(resized, ((side - nw) // 2, (side - nh) // 2), resized)
    return canvas


def main():
    src = Image.open(_source_path())
    print('源图:', src.size, src.mode)

    transparent = white_to_alpha(src)
    bbox = transparent.getbbox()
    print('透明化后内容包围盒:', bbox)
    transparent = transparent.crop(bbox)
    print('裁到内容:', transparent.size)

    out_root = os.path.join(PROJ, 'build', 'icon')
    os.makedirs(out_root, exist_ok=True)

    # 主图（1024）留作两端的高分辨率源
    master_path = os.path.join(out_root, 'icon_master_1024.png')
    fit_square(transparent, 1024).save(master_path)
    print('主图:', master_path)

    # ---------- 应用内 logo（Flutter assets）----------
    # 启动闪屏与登录页要显示校徽本体，而不是 Material 的 `Icons.school`。
    #
    # 与桌面图标分开生成的原因：桌面图标必须留白（`CONTENT_RATIO`，
    # 否则会被相邻图标挤在一起或被系统裁角），而**应用内**是按自己的
    # 布局摆的，留白由 Flutter 的 padding 控制 —— 图里再带一圈透明边
    # 会让「看起来的尺寸」和代码写的尺寸对不上，调间距全在猜。
    # 因此这里紧贴着内容输出，一点边都不留。
    #
    # 宽度取 512：屏上最大也就显示到 150dp 上下，512 在 3x 屏上也够，
    # 而它只有几十 KB —— 不像 `icon_master_1024` 那样是给系统切图用的。
    logo = transparent.resize(
        (512, max(1, round(512 * transparent.height / transparent.width))),
        Image.LANCZOS,
    )
    logo_path = os.path.join(PROJ, 'assets', 'logo.png')
    logo.save(logo_path)
    print('应用内 logo:', logo_path, logo.size, '宽高比%.2f'
          % (logo.width / logo.height))

    # ---------- Android ----------
    # 传统方形图标尺寸。Android 8+ 没有自适应图标时会直接用这张 PNG，
    # 因此**保留透明底** —— 在深色桌面/浅色桌面上都能正常显示。
    android = {
        'mdpi': 48, 'hdpi': 72, 'xhdpi': 96,
        'xxhdpi': 144, 'xxxhdpi': 192,
    }
    res_dir = os.path.join(PROJ, 'android', 'app', 'src', 'main', 'res')
    for d, side in android.items():
        img = fit_square(transparent, side, ratio=CONTENT_RATIO)
        img.save(os.path.join(res_dir, f'mipmap-{d}', 'ic_launcher.png'))
        print(f'  Android mipmap-{d}: {side}x{side}')

    print('完成。')


if __name__ == '__main__':
    main()
