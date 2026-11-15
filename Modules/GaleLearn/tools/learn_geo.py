"""Geometry, physics and 3D helpers for building Gale's course guides.

Lesson space: 1 unit tall, ASPECT units wide (4:3), (0, 0) top left, y goes down.
Every guide in the courses is computed with these helpers, never typed in by hand.
"""
import math

ASPECT = 4.0 / 3.0
GROUND = 0.86
TAU = 2 * math.pi


# ---------------------------------------------------------------- basics

def lerp(a, b, t):
    return a + (b - a) * t


def lerp2(p, q, t):
    return (lerp(p[0], q[0], t), lerp(p[1], q[1], t))


def dist(p, q):
    return math.hypot(p[0] - q[0], p[1] - q[1])


def ease_in(t):
    return t * t


def ease_out(t):
    return 1 - (1 - t) * (1 - t)


def ease_in_out(t):
    return 0.5 - 0.5 * math.cos(math.pi * t)


def length(pts):
    return sum(dist(pts[i - 1], pts[i]) for i in range(1, len(pts)))


def resample(pts, spacing):
    """Points every `spacing` along the line (ends included). Mirrors LearnGeometry.resample."""
    if not pts:
        return []
    if len(pts) == 1:
        return [pts[0]]
    out = [pts[0]]
    carry = 0.0
    for i in range(1, len(pts)):
        a, b = pts[i - 1], pts[i]
        seg = dist(a, b)
        if seg < 1e-12:
            continue
        t = spacing - carry
        while t <= seg:
            out.append(lerp2(a, b, t / seg))
            t += spacing
        carry = seg - (t - spacing)
    if dist(out[-1], pts[-1]) > spacing * 0.05:
        out.append(pts[-1])
    return out


def simplify(pts, tol):
    """Douglas-Peucker."""
    if len(pts) < 3:
        return list(pts)
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        s, e = stack.pop()
        if e - s < 2:
            continue
        best, idx = 0.0, s
        for i in range(s + 1, e):
            d = seg_dist(pts[i], pts[s], pts[e])
            if d > best:
                best, idx = d, i
        if best > tol:
            keep[idx] = True
            stack.append((s, idx))
            stack.append((idx, e))
    return [p for p, k in zip(pts, keep) if k]


def seg_dist(p, a, b):
    abx, aby = b[0] - a[0], b[1] - a[1]
    l2 = abx * abx + aby * aby
    if l2 < 1e-18:
        return dist(p, a)
    t = max(0.0, min(1.0, ((p[0] - a[0]) * abx + (p[1] - a[1]) * aby) / l2))
    return dist(p, (a[0] + abx * t, a[1] + aby * t))


# ---------------------------------------------------------------- 2D shapes

def line(a, b, n=2):
    return [lerp2(a, b, i / (n - 1)) for i in range(n)]


def arc(cx, cy, rx, ry, a0, a1, n=None, rot=0.0):
    """Ellipse arc from angle a0 to a1 (radians, 0 = right, y down so +angle goes clockwise on screen)."""
    if n is None:
        n = max(6, int(abs(a1 - a0) / TAU * 48) + 2)
    c, s = math.cos(rot), math.sin(rot)
    out = []
    for i in range(n):
        a = lerp(a0, a1, i / (n - 1))
        x, y = rx * math.cos(a), ry * math.sin(a)
        out.append((cx + x * c - y * s, cy + x * s + y * c))
    return out


def circle(cx, cy, r, n=None, start=-math.pi / 2):
    """Closed circle (first point not repeated), starting at the top."""
    if n is None:
        n = max(16, min(64, int(r * 160)))
    return [(cx + r * math.cos(start + TAU * i / n), cy + r * math.sin(start + TAU * i / n)) for i in range(n)]


def ellipse(cx, cy, rx, ry, rot=0.0, n=None, start=-math.pi / 2):
    if n is None:
        n = max(16, min(64, int(max(rx, ry) * 160)))
    c, s = math.cos(rot), math.sin(rot)
    out = []
    for i in range(n):
        a = start + TAU * i / n
        x, y = rx * math.cos(a), ry * math.sin(a)
        out.append((cx + x * c - y * s, cy + x * s + y * c))
    return out


def rect(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def polygon(cx, cy, r, sides, start=-math.pi / 2):
    return [(cx + r * math.cos(start + TAU * i / sides), cy + r * math.sin(start + TAU * i / sides)) for i in range(sides)]


def star(cx, cy, r_out, r_in, points=5, start=-math.pi / 2):
    out = []
    for i in range(points * 2):
        r = r_out if i % 2 == 0 else r_in
        a = start + math.pi * i / points
        out.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return out


def bezier(p0, p1, p2, p3, n=24):
    out = []
    for i in range(n):
        t = i / (n - 1)
        u = 1 - t
        x = u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0]
        y = u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]
        out.append((x, y))
    return out


def catmull(points, per=10, closed=False):
    """Smooth curve through the points (Catmull-Rom)."""
    pts = list(points)
    if len(pts) < 3:
        return pts
    out = []
    n = len(pts)
    count = n if closed else n - 1
    for i in range(count):
        p0 = pts[(i - 1) % n] if closed else pts[max(0, i - 1)]
        p1 = pts[i]
        p2 = pts[(i + 1) % n]
        p3 = pts[(i + 2) % n] if closed else pts[min(n - 1, i + 2)]
        for k in range(per):
            t = k / per
            t2, t3 = t * t, t * t * t
            x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2
                       + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2
                       + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
            out.append((x, y))
    if not closed:
        out.append(pts[-1])
    return out


def sine_wave(x0, x1, y, amp, waves, phase=0.0, n=60):
    return [(lerp(x0, x1, i / (n - 1)), y + amp * math.sin(TAU * waves * i / (n - 1) + phase)) for i in range(n)]


def spiral(cx, cy, r0, r1, turns, n=160, start=0.0):
    out = []
    for i in range(n):
        t = i / (n - 1)
        a = start + TAU * turns * t
        r = lerp(r0, r1, t)
        out.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return out


def move(pts, dx, dy):
    return [(x + dx, y + dy) for x, y in pts]


def scale(pts, sx, sy=None, origin=(0.0, 0.0)):
    if sy is None:
        sy = sx
    ox, oy = origin
    return [(ox + (x - ox) * sx, oy + (y - oy) * sy) for x, y in pts]


def rotate(pts, angle, origin=(0.0, 0.0)):
    c, s = math.cos(angle), math.sin(angle)
    ox, oy = origin
    return [(ox + (x - ox) * c - (y - oy) * s, oy + (x - ox) * s + (y - oy) * c) for x, y in pts]


def mirror_x(pts, axis):
    return [(2 * axis - x, y) for x, y in pts]


def squash_ellipse(cx, cy, r, stretch, angle=0.0, n=40):
    """A ball squashed or stretched along `angle` while keeping its area: stretch > 1 is longer."""
    return ellipse(cx, cy, r * stretch, r / stretch, rot=angle, n=n)


def partial(pts, t):
    """The first share t (0..1) of a line, cut at the right length (for 'being drawn' animations)."""
    if t >= 1:
        return list(pts)
    total = length(pts)
    want = total * max(0.0, t)
    out = [pts[0]]
    run = 0.0
    for i in range(1, len(pts)):
        d = dist(pts[i - 1], pts[i])
        if run + d >= want:
            if d > 0:
                out.append(lerp2(pts[i - 1], pts[i], (want - run) / d))
            break
        run += d
        out.append(pts[i])
    if len(out) == 1:
        out.append((out[0][0] + 1e-4, out[0][1]))
    return out


# ---------------------------------------------------------------- 3D

def rot_x(p, a):
    x, y, z = p
    c, s = math.cos(a), math.sin(a)
    return (x, y * c - z * s, y * s + z * c)


def rot_y(p, a):
    x, y, z = p
    c, s = math.cos(a), math.sin(a)
    return (x * c + z * s, y, -x * s + z * c)


def rot_z(p, a):
    x, y, z = p
    c, s = math.cos(a), math.sin(a)
    return (x * c - y * s, x * s + y * c, z)


class Camera:
    """A simple pinhole camera looking down -z at the origin. World y is up; screen y is down.

    `dist` is the camera distance from the origin, `focal` the zoom, `center` where the origin lands.
    `ortho=True` gives a flat (orthographic) view, used for turnarounds.
    """

    def __init__(self, center=(ASPECT / 2, 0.5), scale=0.25, dist=6.0, ortho=False, pitch=0.0, yaw=0.0, height=0.0):
        self.center = center
        self.scale = scale
        self.dist = dist
        self.ortho = ortho
        self.pitch = pitch
        self.yaw = yaw
        self.height = height

    def view(self, p):
        q = rot_y(p, self.yaw)
        q = (q[0], q[1] - self.height, q[2])
        q = rot_x(q, self.pitch)
        return q

    def project(self, p):
        x, y, z = self.view(p)
        if self.ortho:
            k = self.scale
        else:
            k = self.scale * self.dist / max(0.05, self.dist - z)
        return (self.center[0] + x * k, self.center[1] - y * k)

    def depth(self, p):
        return self.view(p)[2]

    def eye(self):
        """Camera position in world space (for back-face tests)."""
        if self.ortho:
            return None
        e = (0.0, 0.0, self.dist)
        e = rot_x(e, -self.pitch)
        e = (e[0], e[1] + self.height, e[2])
        e = rot_y(e, -self.yaw)
        return e

    def facing(self, center, normal):
        """True when a face with this center and outward normal faces the camera."""
        if self.ortho:
            n = self.view_dir(normal)
            return n[2] > 1e-6
        e = self.eye()
        v = (e[0] - center[0], e[1] - center[1], e[2] - center[2])
        return v[0] * normal[0] + v[1] * normal[1] + v[2] * normal[2] > 1e-6

    def view_dir(self, d):
        q = rot_y(d, self.yaw)
        return rot_x(q, self.pitch)


def box_edges(cam, center=(0, 0, 0), size=(1, 1, 1), rot=(0.0, 0.0, 0.0)):
    """Visible and hidden edges of a box, projected. Returns (visible, hidden) lists of 2-point lines."""
    sx, sy, sz = size[0] / 2, size[1] / 2, size[2] / 2
    corners = []
    for i in range(8):
        p = ((sx if i & 1 else -sx), (sy if i & 2 else -sy), (sz if i & 4 else -sz))
        p = rot_x(p, rot[0])
        p = rot_y(p, rot[1])
        p = rot_z(p, rot[2])
        corners.append((p[0] + center[0], p[1] + center[1], p[2] + center[2]))
    faces = [
        ((0, 2, 6, 4), (-1, 0, 0)), ((1, 3, 7, 5), (1, 0, 0)),
        ((0, 1, 5, 4), (0, -1, 0)), ((2, 3, 7, 6), (0, 1, 0)),
        ((0, 1, 3, 2), (0, 0, -1)), ((4, 5, 7, 6), (0, 0, 1)),
    ]
    face_vis = []
    for idx, n in faces:
        n2 = rot_z(rot_y(rot_x(n, rot[0]), rot[1]), rot[2])
        c = tuple(sum(corners[i][k] for i in idx) / 4 for k in range(3))
        face_vis.append((idx, cam.facing(c, n2)))
    edges = {}
    for idx, vis in face_vis:
        for k in range(4):
            a, b = idx[k], idx[(k + 1) % 4]
            key = (min(a, b), max(a, b))
            edges[key] = edges.get(key, False) or vis
    proj = [cam.project(p) for p in corners]
    visible = [[proj[a], proj[b]] for (a, b), v in sorted(edges.items()) if v]
    hidden = [[proj[a], proj[b]] for (a, b), v in sorted(edges.items()) if not v]
    return visible, hidden


def chain_segments(segs, eps=1e-6):
    """Joins 2-point segments that share ends into longer lines (fewer strokes to trace)."""
    segs = [list(s) for s in segs]
    out = []
    while segs:
        cur = segs.pop(0)
        grown = True
        while grown:
            grown = False
            for i, s in enumerate(segs):
                if dist(cur[-1], s[0]) < eps:
                    cur += s[1:]
                elif dist(cur[-1], s[-1]) < eps:
                    cur += list(reversed(s))[1:]
                elif dist(cur[0], s[-1]) < eps:
                    cur = s[:-1] + cur
                elif dist(cur[0], s[0]) < eps:
                    cur = list(reversed(s))[:-1] + cur
                else:
                    continue
                segs.pop(i)
                grown = True
                break
        out.append(cur)
    return out


def visible_runs(points3d, cam, front_test):
    """Splits a 3D curve into the runs where front_test(point) is true, projected to 2D."""
    runs, cur = [], []
    for p in points3d:
        if front_test(p):
            cur.append(cam.project(p))
        else:
            if len(cur) > 1:
                runs.append(cur)
            cur = []
    if len(cur) > 1:
        runs.append(cur)
    return runs


def sphere_circle(axis_rot, lat=0.0, lon=None, n=72, radius=1.0, center=(0, 0, 0)):
    """Points on a sphere: a latitude circle (lon=None) or a longitude half-circle, then rotated by axis_rot (fn)."""
    pts = []
    if lon is None:
        r = math.cos(lat) * radius
        y = math.sin(lat) * radius
        for i in range(n + 1):
            a = TAU * i / n
            p = (r * math.sin(a), y, r * math.cos(a))
            p = axis_rot(p)
            pts.append((p[0] + center[0], p[1] + center[1], p[2] + center[2]))
    else:
        for i in range(n + 1):
            b = -math.pi / 2 + math.pi * i / n
            p = (radius * math.cos(b) * math.sin(lon), radius * math.sin(b), radius * math.cos(b) * math.cos(lon))
            p = axis_rot(p)
            pts.append((p[0] + center[0], p[1] + center[1], p[2] + center[2]))
    return pts


# ---------------------------------------------------------------- physics

def ballistic(y0, v0, g, t):
    """Height (screen y, down positive) of something thrown with speed v0 (negative = up) under gravity g."""
    return y0 + v0 * t + 0.5 * g * t * t


def pendulum_angle(theta0, t, period):
    return theta0 * math.cos(TAU * t / period)


def spring_follow(targets, stiffness=0.35, damping=0.55):
    """A point that chases a target like it's on a spring (overshoots, then settles)."""
    pos = targets[0]
    vel = 0.0
    out = []
    for target in targets:
        vel = vel * damping + (target - pos) * stiffness
        pos += vel
        out.append(pos)
    return out


def pulled_string(points, string):
    """Gale's stabilizer idea: the brush only moves when the string pulls tight."""
    if not points:
        return []
    lazy = points[0]
    out = [lazy]
    for p in points[1:]:
        d = dist(lazy, p)
        if d > string:
            k = (d - string) / d
            lazy = (lazy[0] + (p[0] - lazy[0]) * k, lazy[1] + (p[1] - lazy[1]) * k)
            out.append(lazy)
    out.append(points[-1])
    return out


# ---------------------------------------------------------------- figures

def limb(origin, angles, lengths):
    """Forward kinematics: a chain of bones. Angles are absolute, 0 = straight down, + = forward (right)."""
    pts = [origin]
    x, y = origin
    for a, l in zip(angles, lengths):
        x += l * math.sin(a)
        y += l * math.cos(a)
        pts.append((x, y))
    return pts


def walk_pose(phase, hip_x=ASPECT / 2, ground=GROUND, size=0.62, run=False):
    """A side-view stick figure walking (or running) to the right, in place. phase 0..1 is one full cycle.

    Leg angles follow a smooth gait curve; the hip height comes from the stance foot touching the
    ground, so the up-and-down bob is computed, not guessed. Returns dict of named lines.
    """
    thigh = 0.25 * size
    shin = 0.25 * size
    foot = 0.07 * size
    torso = 0.30 * size
    upper_arm = 0.15 * size
    forearm = 0.14 * size
    head_r = 0.075 * size
    swing = math.radians(42 if run else 26)
    knee_max = math.radians(95 if run else 48)
    lean = math.radians(12 if run else 3)

    def leg_angles(ph):
        # Thigh: forward at contact (ph = 0.25), back at toe-off (ph = 0.75), straight down when passing.
        hip_a = swing * math.sin(TAU * ph)
        # Knee: bends while the leg swings through (around ph = 0, the passing pose), straight in stance.
        lift = max(0.0, math.cos(TAU * (ph + 0.06)))
        knee = knee_max * lift ** 1.5 + math.radians(10 if run else 3)
        # Just after contact the standing knee bends a little to soak up the weight (the "down" pose).
        p = (ph - 0.25) % 1.0
        if p < 0.3:
            knee += math.radians(28 if run else 16) * math.sin(math.pi * p / 0.3)
        return hip_a, hip_a - knee

    legs = []
    lowest = 0.0
    for ph in (phase, phase + 0.5):
        h, k = leg_angles(ph)
        pts = limb((0.0, 0.0), [h, k], [thigh, shin])
        legs.append((pts, ph))
        lowest = max(lowest, pts[-1][1])
    extra_air = 0.0
    if run:
        # In a run the body is pushed up after the stance: a flight phase where both feet leave the ground.
        extra_air = 0.06 * size * max(0.0, math.sin(TAU * 2 * phase - 0.9)) ** 2
    hip_y = ground - foot * 0.3 - lowest - extra_air
    out = {}
    names = ("near_leg", "far_leg")
    for (pts, ph), name in zip(legs, names):
        pts = [(hip_x + x, hip_y + y) for x, y in pts]
        ankle = pts[-1]
        toe = (ankle[0] + foot, ankle[1] + 0.004)
        out[name] = pts + [toe]
    neck = (hip_x + torso * math.sin(lean), hip_y - torso * math.cos(lean))
    out["torso"] = [(hip_x, hip_y), neck]
    head_c = (neck[0] + head_r * 0.5 * math.sin(lean), neck[1] - head_r * 1.05)
    out["head"] = circle(head_c[0], head_c[1], head_r, n=24)
    out["head_center"] = head_c
    shoulder = lerp2((hip_x, hip_y), neck, 0.92)
    for name, ph in (("near_arm", phase + 0.5), ("far_arm", phase)):
        # Arms swing opposite to the leg on the same side.
        a = -0.8 * swing * math.sin(TAU * (ph + 0.5)) * (1.25 if run else 1.0)
        elbow_bend = math.radians(80 if run else 18) + math.radians(10) * max(0.0, math.sin(TAU * ph))
        out[name] = limb(shoulder, [a, a - elbow_bend * -1.0], [upper_arm, forearm])
    out["hip"] = (hip_x, hip_y)
    return out


def figure_lines(pose, parts=("far_leg", "far_arm", "torso", "near_leg", "near_arm", "head")):
    return [(name, pose[name]) for name in parts]
