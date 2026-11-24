# Raiden のアプリアイコン: Kodou-ui の稲妻のドット絵（12×12）を藍のガラスの立方体で組み、白いすりガラスの板に載せる。
# /Applications/Blender.app/Contents/MacOS/Blender -b -P tools/icon/make_icon.py -- docs/icon-1024.png 512 0.35 0.6 8
#   引数: 出力の png、サンプル数、板の光（emission）、ガラスの藍の濃さ（吸収）、カメラの傾き（度）。上が今のアイコンの値
# 書き出すのは角丸の四角の中身（端まで）。tools/icon/finish_icon.py が 824 に縮めて Apple の格子の角丸で切り抜き、1024 に置く
# 開いている Blender で exec すると、今のシーンには触らず「RaidenIcon」シーンに組む（描き出しはしない）
# AppIcon.icns は sips で 16〜1024 の大きさを作り、iconutil -c icns で固める
import bpy, sys, math

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else globals().get("ICON_ARGV", [])
LIVE = "--" not in sys.argv
OUT = argv[0] if argv else "/tmp/raiden-icon.png"
SAMPLES = int(argv[1]) if len(argv) > 1 else 256
EMIT = float(argv[2]) if len(argv) > 2 else 0.5
DENS = float(argv[3]) if len(argv) > 3 else 2.2
TILT = float(argv[4]) if len(argv) > 4 else 0.0

BOLT = [
    "......####..",
    ".....####...",
    "....####....",
    "...####.....",
    "..#######...",
    ".....####...",
    "....####....",
    "...####.....",
    "..###.......",
    ".##.........",
    "#...........",
    "............",
]

if LIVE:
    # 開いている Blender では、今のシーンに触らず新しいシーンを作る
    old = bpy.data.scenes.get("RaidenIcon")
    if old: bpy.data.scenes.remove(old)
    scene = bpy.data.scenes.new("RaidenIcon")
    bpy.context.window.scene = scene
else:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene

def srgb(h):
    def lin(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return (lin((h >> 16) & 255), lin((h >> 8) & 255), lin(h & 255), 1)

def principled(name, **kw):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    for k, v in kw.items():
        b.inputs[k].default_value = v
    return m

# 板（macOS のアイコンの格子: 1024 の中に 824 の角丸の四角、角の半径 185）
PLATE = 8.24
plate_mat = principled("plate", **{"Base Color": srgb(0xEFEFF4), "Roughness": 0.3,
                                    "Coat Weight": 1.0, "Coat Roughness": 0.05})
import bmesh
# 角の丸い四角（Apple のアイコンに近い連続曲率の形: 指数 5 の超楕円を角だけに使う）
def squircle(half, r, n=5, steps=32):
    pts = []
    for cxs, cys, a0 in [(1, 1, 0), (-1, 1, 90), (-1, -1, 180), (1, -1, 270)]:
        ox, oy = cxs * (half - r), cys * (half - r)
        for i in range(steps + 1):
            t = math.radians(a0 + 90 * i / steps)
            c, s_ = math.cos(t), math.sin(t)
            x = r * math.copysign(abs(c) ** (2 / n), c); y = r * math.copysign(abs(s_) ** (2 / n), s_)
            pts.append((ox + x, oy + y))
    return pts
me = bpy.data.meshes.new("plate"); plate = bpy.data.objects.new("plate", me)
scene.collection.objects.link(plate)
bm = bmesh.new()
vs = [bm.verts.new((x, y, -0.6)) for x, y in squircle(PLATE, 2.4)]   # 枠より大きくして縁を写さない（角丸は後で切り抜く）
f = bm.faces.new(vs)
ext = bmesh.ops.extrude_face_region(bm, geom=[f])
for v in [e for e in ext["geom"] if isinstance(e, bmesh.types.BMVert)]: v.co.z = 0
bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
bm.to_mesh(me); bm.free()
pn = plate_mat.node_tree
pb = next(n for n in pn.nodes if n.type == "BSDF_PRINCIPLED")
tc = pn.nodes.new("ShaderNodeTexCoord")
mp = pn.nodes.new("ShaderNodeMapping"); mp.inputs["Scale"].default_value = (1 / 0.44, 1 / 0.44, 1)
pn.links.new(tc.outputs["Object"], mp.inputs["Vector"])
# 1 マスごとに小さな点: 格子の交点からの距離が近い所を少し濃くする
sep = pn.nodes.new("ShaderNodeSeparateXYZ"); pn.links.new(mp.outputs[0], sep.inputs[0])
def frac_dist(axis):
    m1 = pn.nodes.new("ShaderNodeMath"); m1.operation = "FRACT"; pn.links.new(sep.outputs[axis], m1.inputs[0])
    m2 = pn.nodes.new("ShaderNodeMath"); m2.operation = "SUBTRACT"; m2.inputs[1].default_value = 0.5; pn.links.new(m1.outputs[0], m2.inputs[0])
    m3 = pn.nodes.new("ShaderNodeMath"); m3.operation = "ABSOLUTE"; pn.links.new(m2.outputs[0], m3.inputs[0])
    return m3
dx, dy = frac_dist(0), frac_dist(1)
mx = pn.nodes.new("ShaderNodeMath"); mx.operation = "MINIMUM"; pn.links.new(dx.outputs[0], mx.inputs[0]); pn.links.new(dy.outputs[0], mx.inputs[1])
mn = pn.nodes.new("ShaderNodeMath"); mn.operation = "MAXIMUM"; pn.links.new(dx.outputs[0], mn.inputs[0]); pn.links.new(dy.outputs[0], mn.inputs[1])
# 交点（両方の軸で 0.5 に近い）だけ点にする
dot = pn.nodes.new("ShaderNodeMath"); dot.operation = "GREATER_THAN"; dot.inputs[1].default_value = 0.46
pn.links.new(mx.outputs[0], dot.inputs[0])
mix = pn.nodes.new("ShaderNodeMix"); mix.data_type = "RGBA"
mix.inputs["A"].default_value = srgb(0xE8E8EE); mix.inputs["B"].default_value = srgb(0xD3D3DE)
pn.links.new(dot.outputs[0], mix.inputs["Factor"])
pn.links.new(mix.outputs["Result"], pb.inputs["Base Color"])
# 板をわずかに光らせ、ガラスの下まで明るくする（下から光が通るので、藍が透けて見える）
pn.links.new(mix.outputs["Result"], pb.inputs["Emission Color"])
pb.inputs["Emission Strength"].default_value = EMIT
plate.data.materials.append(plate_mat)
bev2 = plate.modifiers.new("edge", "BEVEL"); bev2.width = 0.1; bev2.segments = 8; bev2.limit_method = "ANGLE"
for p_ in me.polygons: p_.use_smooth = True
me.set_sharp_from_angle(angle=math.radians(40)) if hasattr(me, "set_sharp_from_angle") else None

# 稲妻: マスをつなげた 1 つのガラスの塊（外に面した面だけを作り、縁を丸める）。1 マス CELL、厚さ DEPTH
CELL, DEPTH = 0.44, 0.6
glass = principled("glass", **{"Base Color": srgb(0x7A73FF), "Roughness": 0.0, "IOR": 1.45,
                               "Transmission Weight": 1.0, "Coat Weight": 0.8, "Coat Roughness": 0.01})
nt = glass.node_tree
absn = nt.nodes.new("ShaderNodeVolumeAbsorption")
absn.inputs["Color"].default_value = srgb(0x3B34D6); absn.inputs["Density"].default_value = DENS
out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
nt.links.new(absn.outputs[0], out.inputs["Volume"])
cells = {(x, y) for y, r in enumerate(BOLT) for x, ch in enumerate(r) if ch == "#"}
xs = [c[0] for c in cells]; ys = [c[1] for c in cells]
cx = (min(xs) + max(xs) + 1) / 2; cy = (min(ys) + max(ys) + 1) / 2
def P(x, y, z): return ((x - cx) * CELL, -(y - cy) * CELL, z)
# 上下左右でつながったマスごとに別の塊にする（斜めにだけ接するマスで頂点を共有すると形が崩れる）
comps, seen = [], set()
for c in sorted(cells):
    if c in seen: continue
    stack, comp = [c], set()
    while stack:
        q = stack.pop()
        if q in seen or q not in cells: continue
        seen.add(q); comp.add(q)
        x, y = q; stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
    comps.append(comp)
for ci, comp in enumerate(comps):
    bm = bmesh.new(); vmap = {}
    def V(co):
        k = tuple(round(c, 5) for c in co)
        if k not in vmap: vmap[k] = bm.verts.new(co)
        return vmap[k]
    t, b0 = DEPTH, 0.002
    for (x, y) in comp:
        quads = [[P(x, y, t), P(x, y + 1, t), P(x + 1, y + 1, t), P(x + 1, y, t)],
                 [P(x, y, b0), P(x + 1, y, b0), P(x + 1, y + 1, b0), P(x, y + 1, b0)]]
        if (x - 1, y) not in comp: quads.append([P(x, y, b0), P(x, y + 1, b0), P(x, y + 1, t), P(x, y, t)])
        if (x + 1, y) not in comp: quads.append([P(x + 1, y, b0), P(x + 1, y, t), P(x + 1, y + 1, t), P(x + 1, y + 1, b0)])
        if (x, y - 1) not in comp: quads.append([P(x, y, b0), P(x, y, t), P(x + 1, y, t), P(x + 1, y, b0)])
        if (x, y + 1) not in comp: quads.append([P(x, y + 1, b0), P(x + 1, y + 1, b0), P(x + 1, y + 1, t), P(x, y + 1, t)])
        for q in quads: bm.faces.new([V(co) for co in q])
    bmesh.ops.dissolve_limit(bm, angle_limit=math.radians(1), verts=bm.verts, edges=bm.edges)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    gme = bpy.data.meshes.new(f"bolt{ci}"); bolt = bpy.data.objects.new(f"bolt{ci}", gme)
    scene.collection.objects.link(bolt)
    bm.to_mesh(bm_me := gme) if False else bm.to_mesh(gme); bm.free()
    gme.materials.append(glass)
    bolt.location.z = 0.25   # 板から少し浮かせる（影と屈折がずれて見え、ガラスだと分かる）
    bb = bolt.modifiers.new("bev", "BEVEL"); bb.width = 0.13; bb.segments = 10; bb.limit_method = "ANGLE"
    for p_ in gme.polygons: p_.use_smooth = True

# 光: 左上の大きな柔らかい光、右下の弱い返し、上からの細い光（ガラスの縁に線のハイライト）
def area(name, loc, rot, size, power, color=(1, 1, 1)):
    bpy.ops.object.light_add(type="AREA", location=loc, rotation=rot)
    l = bpy.context.object; l.name = name
    l.data.size = size; l.data.energy = power; l.data.color = color
    try: l.data.cycles.is_caustics_light = True
    except Exception: pass
    return l
area("key", (-6, 6, 9), (math.radians(-35), math.radians(-30), 0), 8, 700)
area("fill", (7, -6, 6), (math.radians(45), math.radians(40), 0), 10, 220, (0.85, 0.88, 1.0))
area("rim", (5, 7, 7), (math.radians(-45), math.radians(35), 0), 2, 250)

for nm, loc, rot in [("stripL", (-7, 0, 3), (0, math.radians(-65), 0)), ("stripR", (7, 0, 3), (0, math.radians(65), 0)),
                     ("stripT", (0, 7, 3), (math.radians(-65), 0, 0))]:
    l = area(nm, loc, rot, 1, 110)
    l.data.shape = "RECTANGLE"; l.data.size = 0.4; l.data.size_y = 12
    if nm == "stripT": l.data.size = 12; l.data.size_y = 0.4
world = bpy.data.worlds.new("w"); scene.world = world
world.use_nodes = True
bg = world.node_tree.nodes["Background"]
bg.inputs[0].default_value = (0.92, 0.93, 0.97, 1); bg.inputs[1].default_value = 0.3

# カメラ: 真上から正投影（アイコンは正面を向ける）
t = math.radians(TILT)
bpy.ops.object.camera_add(location=(0, -20 * math.sin(t), 20 * math.cos(t)), rotation=(t, 0, 0))
cam = bpy.context.object
cam.data.type = "ORTHO"; cam.data.ortho_scale = PLATE   # 写すのはアイコンの中身（1024 の中の 824）だけ
scene.camera = cam

scene.render.engine = "CYCLES"
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
scene.cycles.max_bounces = 24; scene.cycles.transmission_bounces = 24; scene.cycles.volume_bounces = 4
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"; prefs.get_devices()
    for d in prefs.devices: d.use = True
    scene.cycles.device = "GPU"
except Exception as e:
    print("GPU なし", e)
scene.render.film_transparent = False
for o in scene.objects:
    try:
        if o.name.startswith("bolt"): o.cycles.is_caustics_caster = True
        if o.name == "plate": o.cycles.is_caustics_receiver = True
    except Exception as e: print("caustics", e)
scene.render.resolution_x = scene.render.resolution_y = 1024
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.view_settings.view_transform = "Standard"
scene.render.filepath = OUT
if not LIVE:
    bpy.ops.render.render(write_still=True)
    print("書き出し", OUT)
else:
    print("組みました", len(scene.objects))
