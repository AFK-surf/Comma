# Builds iphone-duo.glb (this folder), iphone-duo.usdz (clients/apps/apple/Resources/Devices) and iphone-duo.rig.json
# (both), with previews, into <out>:
#   blender -b --factory-startup -P build-iphone-duo.py -- <out>          (DUO_FINISH=black for the black finish)
# An original, parametric iPhone Duo model. Its geometry is written here; the measurements follow the simulator's
# display facts and the device's published proportions (each half 82.4 x 117.2 x 5.0 mm).
# Book fold along Blender's Y axis at x = 0, top of the device at +Y. Open pose: both halves face +Z (inner display).
# `Hinge` turns the cover half about +Y by theta = 180 - opening angle; `SpineHinge` by theta / 2.
import bpy, bmesh, math, os, sys
from mathutils import Vector, Matrix

OUT = sys.argv[sys.argv.index("--") + 1]
FINISH = os.environ.get("DUO_FINISH", "light")
MM = 0.001
PX = 25.4 / 460                      # mm per display pixel
W, H, T = 82.4, 117.2, 5.0           # one half
R_OUT, R_HINGE = 12.3, 1.2           # body corners: away from the hinge, at it
INNER_W, INNER_H = 2853 * PX, 2007 * PX
INNER_R = 55 * 3 * PX
COVER_W, COVER_H = 1398 * PX, 2034 * PX
COVER_R_HINGE, COVER_R_OUT = 8 * 3 * PX, 59 * 3 * PX
LIFT = 0.12
CREASE = 7.9                        # half the bending strip of the inner display (15.8 mm)
PIVOT = 0.475                       # hinge axis above the inner faces: closed halves keep 2 x this apart
SEG = 24                            # corner segments: enough that polished edges reflect without facets

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

def material(name, color, metallic=0.0, rough=0.5, coat=0.0):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Roughness"].default_value = rough
    if coat: b.inputs["Coat Weight"].default_value = coat
    return m

light = FINISH == "light"
M_FRAME = material("Frame", (0.89, 0.85, 0.78) if light else (0.05, 0.06, 0.07), 1.0, 0.14)
M_BACK = material("Back", (0.90, 0.88, 0.84) if light else (0.07, 0.075, 0.085), 0.15, 0.62)
M_PLATE = material("CameraPlate", (0.94, 0.92, 0.87) if light else (0.06, 0.07, 0.08), 1.0, 0.2, coat=0.2)
M_RING = material("LensRing", (0.89, 0.83, 0.73) if light else (0.05, 0.06, 0.07), 1.0, 0.1)
M_GLASS = material("LensGlass", (0.0, 0.0, 0.0), 0.0, 0.05)
M_OPTIC = material("LensOptic", (0.02, 0.03, 0.06), 0.4, 0.15)
M_FLASH = material("Flash", (1.0, 0.98, 0.92), 0.0, 0.33)
M_BLACK = material("Bezel", (0.01, 0.01, 0.012), 0.0, 0.25)
M_PORT = material("Port", (0.015, 0.015, 0.017), 0.3, 0.55)
M_TONGUE = material("PortTongue", (0.04, 0.04, 0.045), 0.0, 0.4)
M_ANT = material("AntennaBreak", (0.60, 0.58, 0.54) if light else (0.035, 0.04, 0.045), 0.0, 0.8)
M_CAMKEY = material("CameraKey", (0.89, 0.845, 0.78) if light else (0.05, 0.06, 0.07), 1.0, 0.02)
M_HOLE = material("CameraHole", (0.0, 0.0, 0.0), 0.0, 0.95)
M_INNER = material("ScreenInner", (0.0, 0.0, 0.0), 0.0, 0.1)
M_COVER = material("ScreenCover", (0.0, 0.0, 0.0), 0.0, 0.1)

def outline(x0, y0, x1, y1, radii, seg=SEG):
    """Rounded rectangle: corners BL, BR, TR, TL with their radii (0: square)."""
    pts = []
    for (cx, cy, sx, sy, start), r in zip(((x0, y0, 1, 1, 180), (x1, y0, -1, 1, 270), (x1, y1, -1, -1, 0), (x0, y1, 1, -1, 90)), radii):
        if r <= 0: pts.append((cx, cy)); continue
        n = max(3, round(seg * min(1.0, r / 6)))
        for i in range(n + 1):
            a = math.radians(start + 90 * i / n)
            pts.append((cx + sx * r + r * math.cos(a), cy + sy * r + r * math.sin(a)))
    return pts

def capsule(cx, cy, w, h, seg=SEG):
    r = min(w, h) / 2
    return outline(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, [r, r, r, r], seg)

def disc(cx, cy, r, n=28):
    return [(cx + r * math.cos(2 * math.pi * k / n), cy + r * math.sin(2 * math.pi * k / n)) for k in range(n)]

def finish(ob, mat, parent, smooth=True):
    ob.data.materials.append(mat); scene.collection.objects.link(ob)
    if parent: ob.parent = parent
    if smooth:
        bpy.context.view_layer.objects.active = ob
        bpy.ops.object.shade_auto_smooth(angle=math.radians(35))
    return ob

def slab(name, pts, z0, z1, mat, bevel=0.0, segs=2, parent=None):
    bm = bmesh.new()
    f = bm.faces.new([bm.verts.new((x * MM, y * MM, z0 * MM)) for x, y in pts])
    ext = bmesh.ops.extrude_face_region(bm, geom=[f])
    bmesh.ops.translate(bm, verts=[e for e in ext["geom"] if isinstance(e, bmesh.types.BMVert)], vec=(0, 0, (z1 - z0) * MM))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    if bevel:
        edges = [e for e in bm.edges if e.calc_face_angle(0) > math.radians(50)]
        bmesh.ops.bevel(bm, geom=edges, offset=bevel * MM, segments=segs, profile=0.5, affect="EDGES", clamp_overlap=True)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    return finish(bpy.data.objects.new(name, me), mat, parent)

def face(name, pts, z, mat, uv_box=None, down=False, parent=None):
    bm = bmesh.new()
    vs = [bm.verts.new((x * MM, y * MM, z * MM)) for x, y in pts]
    f = bm.faces.new(list(reversed(vs)) if down else vs)
    if uv_box:
        uv = bm.loops.layers.uv.new("UVMap"); x0, y0, x1, y1 = uv_box
        for loop in f.loops:
            p = loop.vert.co / MM
            loop[uv].uv = ((p.x - x0) / (x1 - x0), (p.y - y0) / (y1 - y0))
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    return finish(bpy.data.objects.new(name, me), mat, parent, smooth=False)

def empty(name, parent=None):
    e = bpy.data.objects.new(name, None); e.empty_display_size = 0.01
    scene.collection.objects.link(e)
    if parent: e.parent = parent
    return e

root = empty("Duo")
y0, y1 = -H / 2, H / 2
zb, zt = -T, 0.0

# ---- Camera half (fixed, x in [0, W]): its back carries the cameras; its outer edge the side buttons.
fixed = slab("Body_Camera", outline(0, y0, W, y1, [R_HINGE, R_OUT, R_OUT, R_HINGE]), zb, zt, M_FRAME, bevel=1.2, segs=6, parent=root)
face("Back_Camera", outline(0.9, y0 + 0.9, W - 0.9, y1 - 0.9, [R_HINGE, R_OUT - 0.9, R_OUT - 0.9, R_HINGE]), zb - 0.06, M_BACK, down=True, parent=fixed)
# Inner display: one picture across both halves (u across the open device, v up it).
ix, iy = (2 * W - INNER_W) / 2, (H - INNER_H) / 2
inner_uv = (-W + ix, y0 + iy, W - ix, y1 - iy)
face("Bezel_Camera", outline(0, y0 + 0.9, W - 0.9, y1 - 0.9, [0, R_OUT - 0.9, R_OUT - 0.9, 0]), zt + 0.01, M_BLACK, parent=fixed)
face("ScreenInner_Camera", outline(CREASE, y0 + iy, W - ix, y1 - iy, [0, INNER_R, INNER_R, 0]), zt + LIFT, M_INNER, inner_uv, parent=fixed)

# Camera plateau: a horizontal capsule 34 x 16 mm, 7.2 mm from the outer edge and the top; lenses 16.2 mm across.
pc_x, pc_y = W - 7.2 - 17.0, y1 - 15.2
slab("CameraPlate", capsule(pc_x, pc_y, 34.0, 16.1), zb - 1.9, zb + 0.2, M_PLATE, bevel=0.6, parent=fixed)
for i, lx in enumerate((W - 15.3, W - 33.1)):
    slab(f"LensRing_{i}", disc(lx, pc_y, 7.0, 32), zb - 2.6, zb - 1.8, M_RING, bevel=0.25, segs=1, parent=fixed)
    face(f"LensGlass_{i}", disc(lx, pc_y, 6.4, 32), zb - 2.62, M_GLASS, down=True, parent=fixed)
    face(f"LensOptic_{i}", disc(lx, pc_y, 3.85, 24), zb - 2.64, M_OPTIC, down=True, parent=fixed)
    face(f"LensCore_{i}", disc(lx, pc_y, 1.7, 16), zb - 2.66, M_GLASS, down=True, parent=fixed)
face("Flash", disc(W - 49.7, y1 - 19.6, 2.0, 20), zb - 0.14, M_FLASH, down=True, parent=fixed)
face("Sensor", capsule(W - 49.7, y1 - 10.9, 3.4, 1.6, 4), zb - 0.14, M_BLACK, down=True, parent=fixed)

def edge_slot(name, cx, length, height, y, parent, zc=-T / 2):
    """A stadium-shaped dark slot on the top (y > 0) or bottom edge, facing out."""
    r = height / 2
    pts = []
    for k in range(9):
        a = math.radians(90 + 180 * k / 8)
        pts.append((cx - length / 2 + r + r * math.cos(a), zc + r * math.sin(a)))
    for k in range(9):
        a = math.radians(-90 + 180 * k / 8)
        pts.append((cx + length / 2 - r + r * math.cos(a), zc + r * math.sin(a)))
    bm = bmesh.new()
    vs = [bm.verts.new((x * MM, y * MM, z * MM)) for x, z in pts]
    bm.faces.new(vs if y > 0 else list(reversed(vs)))
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    return finish(bpy.data.objects.new(name, me), M_BLACK, parent, smooth=False)

# ---- Cover half (on the hinge, x in [-W, 0] open): its back carries the cover display.
hinge = empty("Hinge", parent=root)
hinge.location = (0, 0, PIVOT * MM)
fold = slab("Body_Cover", outline(-W, y0, 0, y1, [R_OUT, R_HINGE, R_HINGE, R_OUT]), zb, zt, M_FRAME, bevel=1.2, segs=6, parent=hinge)
fold.location = (0, 0, -PIVOT * MM)  # its geometry is laid out with the axis at the origin
face("Bezel_Cover", outline(-W + 0.9, y0 + 0.9, 0, y1 - 0.9, [R_OUT - 0.9, 0, 0, R_OUT - 0.9]), zt + 0.01, M_BLACK, parent=fold)
face("ScreenInner_Cover", outline(-W + ix, y0 + iy, -CREASE, y1 - iy, [INNER_R, 0, 0, INNER_R]), zt + LIFT, M_INNER, inner_uv, parent=fold)
# (edge openings, buttons and antenna breaks: see "Edge features" below)
# The cover display and its glass, laid out as they show when closed (x in [0, W] on top, the hinge at their left),
# then turned onto this half's back by the inverse of the closed hinge.
cx_, cy_ = (W - COVER_W) / 2, (H - COVER_H) / 2
turn = Matrix.Rotation(math.radians(-180), 4, "Y")
cover_glass = face("Bezel_Outer", outline(0.9, y0 + 0.9, W - 0.9, y1 - 0.9, [R_HINGE, R_OUT - 0.9, R_OUT - 0.9, R_HINGE]), T + 0.01, M_BLACK, parent=fold)
cover = face("ScreenCover", outline(cx_, y0 + cy_, W - cx_, y1 - cy_, [COVER_R_HINGE, COVER_R_OUT, COVER_R_OUT, COVER_R_HINGE]),
             T + LIFT, M_COVER, (cx_, y0 + cy_, W - cx_, y1 - cy_), parent=fold)
# The cover's front camera: a small round hole near its top outer corner (no island).
punch = face("CoverCamera", disc(W - 10.7, y1 - 10.6, 1.8, 20), T + LIFT + 0.05, M_HOLE, parent=fold)
punch_lens = face("CoverCameraLens", disc(W - 10.7, y1 - 10.6, 0.8, 12), T + LIFT + 0.08, M_OPTIC, parent=fold)
for ob in (cover_glass, cover, punch, punch_lens):
    ob.data.transform(turn)


# ---- Edge features, measured along each edge from the hinge (d), in mm. Openings are cut into the bodies; their walls
# take the dark port material.
ZC = -2.37                          # height of buttons and holes in a half's thickness
def stadium(c, z, length, height, n=8):
    """Stadium outline in (along, z): a slot `length` long and `height` tall, centred at (c, z)."""
    r = height / 2; pts = []
    for k in range(n + 1):
        a = math.radians(90 + 180 * k / n); pts.append((c - length / 2 + r + r * math.cos(a), z + r * math.sin(a)))
    for k in range(n + 1):
        a = math.radians(-90 + 180 * k / n); pts.append((c + length / 2 - r + r * math.cos(a), z + r * math.sin(a)))
    return pts
def prism(name, prof, axis, a0, a1, mat, parent):
    """Extrude a (u, z) outline along `axis`: 'y' (u is x) or 'x' (u is y), from a0 to a1."""
    bm = bmesh.new()
    def v(u, z, t): return bm.verts.new(((u if axis == "y" else t) * MM, (t if axis == "y" else u) * MM, z * MM))
    lo = [v(u, z, a0) for u, z in prof]; hi = [v(u, z, a1) for u, z in prof]
    for i in range(len(prof)):
        j = (i + 1) % len(prof); bm.faces.new([lo[i], lo[j], hi[j], hi[i]])
    bm.faces.new(lo); bm.faces.new(list(reversed(hi)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me); scene.collection.objects.link(ob); me.materials.append(mat)
    ob.parent = parent.parent; ob.location = parent.location
    return ob
def cut(body, cutters):
    bpy.context.view_layer.update()
    for c in cutters:
        mod = body.modifiers.new("Cut", "BOOLEAN"); mod.operation = "DIFFERENCE"; mod.object = c; mod.solver = "EXACT"
        mod.material_mode = "TRANSFER"
        bpy.context.view_layer.objects.active = body
        bpy.ops.object.modifier_apply(modifier=mod.name)
        bpy.data.objects.remove(c, do_unlink=True)
def disc_xz(cx, cz, r, n=12):
    return [(cx + r * math.cos(2 * math.pi * k / n), cz + r * math.sin(2 * math.pi * k / n)) for k in range(n)]
def holes(sign, d0, d1, count, dia, y_edge, inward):
    pitch = (d1 - d0 - dia) / (count - 1)
    return [prism("Hole", disc_xz(sign * (d0 + dia / 2 + i * pitch), ZC, dia / 2), "y", y_edge - inward * 1.0, y_edge + inward * 2.0, M_PORT, body_of[sign])
            for i in range(count)]
body_of = {1: fixed, -1: fold}
for sign, body in ((1, fixed), (-1, fold)):
    cutters = []
    # bottom: a shallow stadium recess on both halves (the cover half's holds the USB-C port)
    cutters.append(prism("Recess", stadium(sign * 40.95, ZC + 0.16, 17.3, 2.6), "y", y0 - 1.0, y0 + 0.25, M_FRAME, body))
    if sign == -1:
        cutters.append(prism("PortCut", stadium(-40.98, -2.21, 8.42, 2.5, 10), "y", y0 - 1.0, y0 + 6.9, M_PORT, body))
    else:
        cutters += holes(1, 15.3, 23.9, 4, 1.5, y0, 1)      # bottom speaker
        cutters += holes(1, 58.0, 66.6, 4, 1.5, y0, 1)
    if sign == -1:
        cutters += holes(-1, 33.0, 49.0, 6, 1.4, y1, -1)    # top speaker on the cover half
    else:
        # top: two volume keys, 10.9 mm each, 2.5 mm apart
        cutters.append(prism("VolUpGap", stadium(42.64, -2.37, 10.9 + 0.3, 2.36 + 0.3), "y", y1 - 0.5, y1 + 1.0, M_PORT, body))
        cutters.append(prism("VolDownGap", stadium(56.05, -2.37, 10.9 + 0.3, 2.36 + 0.3), "y", y1 - 0.5, y1 + 1.0, M_PORT, body))
        # outer side: the power key (upper) and the flush camera key (lower), apart
        cutters.append(prism("PowerGap", stadium(15.9, -2.37, 18.6 + 0.3, 3.07 + 0.3), "x", W - 0.5, W + 1.0, M_PORT, body))
        cutters.append(prism("CameraKeyGap", stadium(-26.0, -2.37, 16.8 + 0.3, 2.54 + 0.3), "x", W - 0.6, W + 1.0, M_PORT, body))
    cut(body, cutters)
# USB-C tongue
slab("PortTongue", outline(-40.98 - 3.3, y0 + 1.4, -40.98 + 3.3, y0 + 6.7, [0.3] * 4, 3), -2.21 - 0.35, -2.21 + 0.35, M_TONGUE, parent=fold)
# Buttons: two on the camera half's outer edge (16.8 and 18.3 mm), one on its top edge (24.3 mm), 0.44 proud.
def key(name, prof, axis, a0, a1):
    ob = prism(name, prof, axis, a0, a1, M_FRAME, fixed)
    ob.parent = fixed; ob.location = (0, 0, 0)
    bpy.context.view_layer.objects.active = ob; bpy.ops.object.shade_auto_smooth(angle=math.radians(35))
key("Key_Power", stadium(15.9, -2.37, 18.6, 3.07), "x", W - 0.5, W + 0.43)          # y 6.6 .. 25.2, 0.43 proud
camera_key = prism("Key_Camera", stadium(-26.0, -2.37, 16.8, 2.54), "x", W - 0.6, W - 0.03, M_CAMKEY, fixed)  # flush
camera_key.parent = fixed; camera_key.location = (0, 0, 0)
key("Key_VolumeUp", stadium(42.64, -2.37, 10.9, 2.36), "y", y1 - 0.5, y1 + 0.44)    # top, 37.2 .. 48.1 from the hinge
key("Key_VolumeDown", stadium(56.05, -2.37, 10.9, 2.36), "y", y1 - 0.5, y1 + 0.44)  # top, 50.6 .. 61.5
# Antenna breaks: 1.25 mm grooves across the whole edge, 0.25 deep, lined in the antenna material.
def groove(body, sign, edge, at):
    if edge in ("top", "bottom"):
        ye = y1 if edge == "top" else y0
        lo_, hi_ = (ye - 0.25, ye + 1.0) if edge == "top" else (ye - 1.0, ye + 0.25)
        return prism("Groove", [(sign * at - 0.625, -T - 1), (sign * at + 0.625, -T - 1), (sign * at + 0.625, 1), (sign * at - 0.625, 1)], "y", lo_, hi_, M_ANT, body)
    xe = sign * W
    lo_, hi_ = (xe - 0.25, xe + 1.0) if sign > 0 else (xe - 1.0, xe + 0.25)
    return prism("Groove", [(at - 0.625, -T - 1), (at + 0.625, -T - 1), (at + 0.625, 1), (at - 0.625, 1)], "x", lo_, hi_, M_ANT, body)
for sign, body in ((1, fixed), (-1, fold)):
    cut(body, [groove(body, sign, "top", at) for at in (15.45, 65.35)] + [groove(body, sign, "bottom", at) for at in (28.6, 53.35)]
        + [groove(body, sign, "side", at) for at in (-42.0, 42.0)])

# ---- Spine: a rounded flat bar 8.2 x 2.9 mm along the hinge. Open, it lies under the hinge inside the halves; closed,
# it stands on the hinge edge, 2.3 mm out, covering the gap between the halves. It turns by half the fold, along the
# path a real hinge's links give it (keyed below), not about the axis.
SPINE_W, SPINE_T, SPINE_R = 8.2, 2.9, 1.2
spine_hinge = empty("SpineHinge", parent=root)
bm = bmesh.new()
prof = outline(-SPINE_W / 2, -SPINE_T / 2, SPINE_W / 2, SPINE_T / 2, [SPINE_R] * 4, 6)
lo = [bm.verts.new((x * MM, (y0 + 1.2) * MM, z * MM)) for x, z in prof]
hi = [bm.verts.new((x * MM, (y1 - 1.2) * MM, z * MM)) for x, z in prof]
for i in range(len(prof)):
    j = (i + 1) % len(prof)
    bm.faces.new([lo[i], lo[j], hi[j], hi[i]])
bm.faces.new(lo); bm.faces.new(list(reversed(hi)))
bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
me = bpy.data.meshes.new("Spine"); bm.to_mesh(me); bm.free()
finish(bpy.data.objects.new("Spine", me), M_FRAME, spine_hinge)
# The bar's centre from the axis (x, z mm) at each opening angle, as the device's hinge carries it.
SPINE_PATH = {180: (0.0, -2.45), 135: (-0.68, -1.64), 90: (-0.625, -0.625), 45: (-0.805, -0.335), 0: (-0.875, 0.0)}

# ---- The inner display's bending strip: its two edges ride the halves' screens, its middle bends between them with
# the same length at every angle (a cubic whose handles are solved for that length), sampled evenly along its length so
# the picture does not stretch. One morph target per 15 degrees of fold; the animation blends neighbours.
CREASE_N = 18
def crease_curve(theta_deg):
    th = math.radians(theta_deg)
    L = 2 * CREASE
    A = Vector((CREASE, LIFT)); dA = Vector((-1.0, 0.0))
    rel = Vector((-CREASE, LIFT - PIVOT))
    B = Vector((rel.x * math.cos(th) + rel.y * math.sin(th), PIVOT - rel.x * math.sin(th) + rel.y * math.cos(th)))
    dB = Vector((-math.cos(th), math.sin(th)))   # the way along the strip at B, into the cover half
    def bez(h, t):
        P1 = A + dA * h; P2 = B - dB * h
        u = 1 - t
        return A * u ** 3 + P1 * 3 * u * u * t + P2 * 3 * u * t * t + B * t ** 3
    def length(h, n=240):
        pts = [bez(h, i / n) for i in range(n + 1)]
        return sum((pts[i + 1] - pts[i]).length for i in range(n))
    lo_, hi_ = 0.0, 4 * L
    if length(lo_) >= L:
        h = lo_
    else:
        for _ in range(60):
            mid = (lo_ + hi_) / 2
            if length(mid) < L: lo_ = mid
            else: hi_ = mid
        h = (lo_ + hi_) / 2
    dense = [bez(h, i / 600) for i in range(601)]
    acc = [0.0]
    for i in range(600): acc.append(acc[-1] + (dense[i + 1] - dense[i]).length)
    total = acc[-1]; out = []; j = 0
    for k in range(CREASE_N + 1):
        want = total * k / CREASE_N
        while j < 599 and acc[j + 1] < want: j += 1
        f_ = (want - acc[j]) / max(acc[j + 1] - acc[j], 1e-9)
        out.append(dense[j].lerp(dense[j + 1], f_))
    return out, total
bm = bmesh.new()
uv = bm.loops.layers.uv.new("UVMap")
flat_pts, _ = crease_curve(0)
rows = (y0 + iy, y1 - iy)
grid = [[bm.verts.new((p.x * MM, y * MM, p.y * MM)) for y in rows] for p in flat_pts]
x0u, y0u, x1u, y1u = inner_uv
for k in range(CREASE_N):
    f = bm.faces.new([grid[k][0], grid[k + 1][0], grid[k + 1][1], grid[k][1]])
    for loop in f.loops:
        idx = 0 if loop.vert in grid[k] else 1
        xs = CREASE - 2 * CREASE * (k + idx) / CREASE_N
        loop[uv].uv = ((xs - x0u) / (x1u - x0u), (loop.vert.co.y / MM - y0u) / (y1u - y0u))
bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
me = bpy.data.meshes.new("ScreenInner_Crease"); bm.to_mesh(me); bm.free()
crease = bpy.data.objects.new("ScreenInner_Crease", me); scene.collection.objects.link(crease)
me.materials.append(M_INNER); crease.parent = root
for p in me.polygons: p.use_smooth = True
crease.shape_key_add(name="Open", from_mix=False)
# Every 5 degrees: between two targets the strip is blended, and its ends leave the halves' screens by little enough
# that no seam shows (at 15 a laptop's 110 showed the bezel through a gap).
CREASE_STEP = 5
CREASE_STEPS = list(range(CREASE_STEP, 181, CREASE_STEP))
for th in CREASE_STEPS:
    key = crease.shape_key_add(name=f"Fold{th}", from_mix=False)
    pts, total = crease_curve(th)
    for k, p in enumerate(pts):
        for r_, y in enumerate(rows):
            key.data[k * 2 + r_].co = (p.x * MM, y * MM, p.y * MM)
    print("CREASE", th, round(total, 2))

# ---- Shading, once every cut is made: smooth faces, hard only where faces meet at 30 degrees or more, so rounded
# corners and edges read as one curve (booleans and the per-part smoothing applied before them leave flat bands).
for ob in scene.objects:
    if ob.type != "MESH":
        continue
    for mod in [m for m in ob.modifiers if m.type == "NODES"]:
        ob.modifiers.remove(mod)
    ob.data.shade_smooth()
    ob.data.set_sharp_from_angle(angle=math.radians(30))

# ---- Fold animation: frame = 180 - opening angle (0 open, 180 closed), linear between keys.
def pose(opening):
    th = math.radians(180 - opening)
    hinge.rotation_euler = (0, th, 0)
    sx, sz = SPINE_PATH[opening]
    spine_hinge.location = (sx * MM, 0, (PIVOT + sz) * MM)
    spine_hinge.rotation_euler = (0, th / 2, 0)
scene.frame_start, scene.frame_end = 0, 180
def spine_at(opening):
    """The bar's centre (x, z from the axis) on the measured path, pushed out of the open corner where the bending
    screen passes, so the screen stays clear of it by 0.2 mm."""
    keys_ = sorted(SPINE_PATH)
    lo_k = max(k for k in keys_ if k <= opening); hi_k = min(k for k in keys_ if k >= opening)
    t = 0 if hi_k == lo_k else (opening - lo_k) / (hi_k - lo_k)
    c = Vector(SPINE_PATH[lo_k]).lerp(Vector(SPINE_PATH[hi_k]), t)
    th = math.radians(180 - opening); a = th / 2
    if opening in (0, 180):
        return c
    if opening < 45:
        # nearly closed: the screen is out of sight; ease from the 45-degree position to the closed one
        return Vector(SPINE_PATH[0]).lerp(spine_at(45), opening / 45)
    pts, _ = crease_curve(180 - opening)
    out_dir = -Vector((math.sin(th), 1 + math.cos(th))).normalized()
    u = Vector((math.cos(a), -math.sin(a))); v = Vector((math.sin(a), math.cos(a)))
    def hits(cc):
        centre = Vector((cc.x, PIVOT + cc.y))
        for p in pts:
            d = p - centre
            if abs(d.dot(u)) < SPINE_W / 2 + 0.2 and abs(d.dot(v)) < SPINE_T / 2 + 0.2:
                return True
        return False
    while hits(c):
        c = c + out_dir * 0.05
    return c
for opening in range(180, -1, -15):
    th = math.radians(180 - opening)
    hinge.rotation_euler = (0, th, 0)
    c = spine_at(opening)
    spine_hinge.location = (c.x * MM, 0, (PIVOT + c.y) * MM)
    spine_hinge.rotation_euler = (0, th / 2, 0)
    if opening in (180, 0): hinge.keyframe_insert("rotation_euler", frame=180 - opening)
    spine_hinge.keyframe_insert("rotation_euler", frame=180 - opening)
    spine_hinge.keyframe_insert("location", frame=180 - opening)
    print("SPINE", opening, round(c.x, 2), round(c.y, 2))
keys = crease.data.shape_keys
for th in CREASE_STEPS:
    kb = keys.key_blocks[f"Fold{th}"]
    for fr, v in ((th - CREASE_STEP, 0.0), (th, 1.0), (th + CREASE_STEP, 0.0)):
        if 0 <= fr <= 180:
            kb.value = v; kb.keyframe_insert("value", frame=fr)
    kb.value = 0.0
def linear(e):
    act = e.animation_data.action
    curves = list(getattr(act, "fcurves", []) or [])
    for layer in getattr(act, "layers", []):
        for strip in layer.strips:
            for bag in strip.channelbags: curves += list(bag.fcurves)
    for fc in curves:
        for kp in fc.keyframe_points: kp.interpolation = "LINEAR"
for e in (hinge, spine_hinge): linear(e)
for fc in (keys.animation_data.action.fcurves if hasattr(keys.animation_data.action, "fcurves") else []):
    for kp in fc.keyframe_points: kp.interpolation = "LINEAR"
try:
    for layer in keys.animation_data.action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                for fc in bag.fcurves:
                    for kp in fc.keyframe_points: kp.interpolation = "LINEAR"
except AttributeError:
    pass
scene.frame_set(0)

os.makedirs(OUT, exist_ok=True)
name = "iphone-duo" if light else "iphone-duo-black"
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, name + ".blend"))
kw = dict(filepath=os.path.join(OUT, name + ".glb"), export_format="GLB", export_animations=True, export_apply=True, export_yup=True)
try:
    bpy.ops.export_scene.gltf(**kw, export_animation_mode="SCENE")
except TypeError:
    bpy.ops.export_scene.gltf(**kw)

# ---- USDZ for SceneKit (posed open; the hinge and spine are driven by the rig), and the rig every client drives.
import json
try:
    # Triangles only: SceneKit on iOS splits polygons itself and makes an empty index buffer of some, which Metal refuses.
    bpy.ops.wm.usd_export(filepath=os.path.join(OUT, name + ".usdz"), export_animation=False, export_materials=True,
                          export_uvmaps=True, export_normals=True, generate_preview_surface=True,
                          triangulate_meshes=True)
except Exception as e:
    print("USDZ", e)
rig = {
    "units": "millimetres; Blender axes (x across the open device, y along the hinge with the top at +y, z out of the inner display); glTF swaps to x, z, -y",
    "half": {"width": W, "height": H, "thickness": T},
    "hinge": {"node": "Hinge", "axis": "+y", "pivot": [0, 0, PIVOT], "angle": "180 - opening, degrees"},
    "spine": {"node": "SpineHinge", "angle": "(180 - opening) / 2, degrees",
              "path": {str(o): [round(spine_at(o).x, 3), 0, round(PIVOT + spine_at(o).y, 3)] for o in range(0, 181, 15)}},
    "crease": {"node": "ScreenInner_Crease", "half_width": CREASE, "lift": LIFT, "segments": CREASE_N,
               "rows": [y0 + iy, y1 - iy], "morph": "Fold<theta> for theta = 5..180 step 5"},
    "screens": {"inner": {"nodes": ["ScreenInner_Camera", "ScreenInner_Crease", "ScreenInner_Cover"], "uv_box": list(inner_uv),
                          "u": "across the open device from the cover half (u 0) to the camera half (u 1)", "v": "along the hinge, top v 1"},
                "cover": {"node": "ScreenCover", "uv_box": [cx_, y0 + cy_, W - cx_, y1 - cy_],
                          "u": "across, from the hinge (u 0) when closed and seen from outside", "v": "along the hinge, top v 1"}},
    "animation": {"fps": scene.render.fps, "frame": "180 - opening"},
}
json.dump(rig, open(os.path.join(OUT, name + ".rig.json"), "w"), indent=1)

# ---- Previews (not exported): screens show a pattern whose corners say the picture's way up.
for m in (M_INNER, M_COVER):
    nt = m.node_tree; out = nt.nodes["Material Output"]
    tc = nt.nodes.new("ShaderNodeTexCoord"); sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    comb = nt.nodes.new("ShaderNodeCombineXYZ"); comb.inputs["Z"].default_value = 0.3
    em = nt.nodes.new("ShaderNodeEmission"); em.inputs["Strength"].default_value = 0.8
    nt.links.new(tc.outputs["UV"], sep.inputs[0]); nt.links.new(sep.outputs["X"], comb.inputs["X"]); nt.links.new(sep.outputs["Y"], comb.inputs["Y"])
    nt.links.new(comb.outputs[0], em.inputs["Color"]); nt.links.new(em.outputs[0], out.inputs["Surface"])
world = bpy.data.worlds.new("W"); scene.world = world; world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.8, 0.8, 0.82, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.7
for nm, loc, e in (("Key", (0.3, -0.25, 0.45), 40), ("Fill", (-0.35, -0.15, 0.2), 18), ("Rim", (0.05, 0.4, 0.25), 25), ("Under", (0.0, -0.1, -0.45), 5)):
    ld = bpy.data.lights.new(nm, "AREA"); ld.energy = e; ld.size = 0.45
    lo_ = bpy.data.objects.new(nm, ld); lo_.location = loc; scene.collection.objects.link(lo_)
    lo_.rotation_euler = (-Vector(loc)).to_track_quat("-Z", "Y").to_euler()
cd = bpy.data.cameras.new("Cam"); cd.lens = 70
cam = bpy.data.objects.new("Cam", cd); scene.collection.objects.link(cam); scene.camera = cam
scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x, scene.render.resolution_y = 1000, 800
for opening, label, eye, up in ((135, "crease-135", (0.0, -0.14, 0.05), "Z"), (90, "crease-90", (0.06, -0.14, 0.06), "Z"),
                                (45, "crease-45", (0.07, -0.16, 0.04), "Z"), (0, "port", (0.0, -0.05, -0.012), "Z"),
                                (0, "hinge-closed-end", (0.0, -0.16, 0.0), "Z"), (90, "hinge-half-end", (0.0, -0.2, 0.0), "Z"),
                                (0, "hinge-closed-edge", (-0.12, -0.08, 0.03), "Z"),
                                (0, "closed-cover", (0.20, -0.30, 0.42), "Y"), (0, "closed-back", (-0.12, -0.32, -0.42), "Y"),
                                (100, "half", (0.38, -0.40, 0.30), "Z"), (180, "open", (0.0, -0.40, 0.45), "Z")):
    scene.frame_set(180 - opening); bpy.context.view_layer.update()
    target = Vector((W / 2 * MM if opening < 90 else 0.0, 0, -T * MM))
    if label.startswith("crease"):
        target = Vector((0.0, 0.0, 0.006)); cd.lens = 100
    elif label == "port":
        target = Vector((W / 2 * MM, -H / 2 * MM, (PIVOT * 2 + T - 2.2 + 0.0) * MM)); cd.lens = 120
    elif label.startswith("hinge"):
        target = Vector((0.0, 0.0, PIVOT * MM if opening == 0 else 0.01))
        cd.lens = 120 if label != "hinge-closed-edge" else 70
    else:
        cd.lens = 70
    cam.location = target + Vector(eye)
    q = (target - cam.location).to_track_quat("-Z", up)
    if label == "closed-back":
        from mathutils import Quaternion
        q = q @ Quaternion((0, 0, 1), math.pi)
    cam.rotation_euler = q.to_euler()
    scene.render.filepath = os.path.join(OUT, f"{name}-{label}.png")
    bpy.ops.render.render(write_still=True)
print("DONE")
