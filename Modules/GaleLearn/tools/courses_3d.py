"""Track "3D in 2D": perspective, turnarounds, rotating objects, camera moves and 3D characters.
Every drawing here is a real 3D model projected through a camera."""
import math

from learn_geo import (ASPECT, TAU, Camera, box_edges, catmull, circle, dist, ease_in_out, ellipse, lerp, line, move,
                       rect, rot_x, rot_y, sphere_circle, visible_runs)
from learn_dsl import (F, G, accent, chk_loop, chk_smooth, chk_spacing, chk_straight, course, frames, helper, ink,
                       lesson, quiz, read, still, tool, trace)
from content_kit import CX, dot, mountains, tree

TRACK = "3d"


# ---------------------------------------------------------------- 3D helpers

def vanishing_point(cam, d):
    """Where lines going in direction d (world) meet on the picture."""
    v = cam.view_dir(d)
    if v[2] >= 0:
        v = (-v[0], -v[1], -v[2])
    k = cam.scale * cam.dist / max(1e-6, -v[2])
    return (cam.center[0] + v[0] * k, cam.center[1] - v[1] * k)


def circle3d(center, radius, axis="y", n=48):
    cx, cy, cz = center
    pts = []
    for i in range(n + 1):
        a = TAU * i / n
        if axis == "y":
            pts.append((cx + radius * math.sin(a), cy, cz + radius * math.cos(a)))
        elif axis == "x":
            pts.append((cx, cy + radius * math.sin(a), cz + radius * math.cos(a)))
        else:
            pts.append((cx + radius * math.cos(a), cy + radius * math.sin(a), cz))
    return pts


def cylinder(cam, center, radius, height, n=48):
    """A standing cylinder seen from above eye level: full top ellipse, front half of the bottom, two sides."""
    cx, cy, cz = center
    top = [cam.project(p) for p in circle3d((cx, cy + height / 2, cz), radius, n=n)][:-1]
    bot = [cam.project(p) for p in circle3d((cx, cy - height / 2, cz), radius, n=n)][:-1]
    i0 = min(range(n), key=lambda i: bot[i][0])
    i1 = max(range(n), key=lambda i: bot[i][0])
    arc_a = [bot[(i0 + k) % n] for k in range((i1 - i0) % n + 1)]
    arc_b = [bot[(i1 + k) % n] for k in range((i0 - i1) % n + 1)]
    front = arc_a if sum(p[1] for p in arc_a) / len(arc_a) > sum(p[1] for p in arc_b) / len(arc_b) else arc_b
    t0 = min(range(n), key=lambda i: top[i][0])
    t1 = max(range(n), key=lambda i: top[i][0])
    return {"top": top, "bottom": front, "left": [top[t0], bot[i0]], "right": [top[t1], bot[i1]]}


def cylinder_paths(cam, center, radius, height):
    c = cylinder(cam, center, radius, height)
    return [ink(c["top"], closed=True), ink(c["bottom"]), ink(c["left"]), ink(c["right"])]


def sphere_lines(cam, yaw=0.0, pitch=0.0, center=(0.0, 0.0, 0.0), radius=1.0, lats=(0.0,), lons=(0.0,)):
    """Visible parts of latitude and longitude lines on a ball (orthographic)."""
    def spin(p):
        return rot_x(rot_y(p, yaw), pitch)
    out = []
    front = lambda p: cam.view((p[0] - center[0], p[1] - center[1], p[2] - center[2]))[2] > 0.0
    for lat in lats:
        out += visible_runs(sphere_circle(spin, lat=lat, radius=radius, center=center, n=96), cam, front)
    for lon in lons:
        out += visible_runs(sphere_circle(spin, lon=lon, radius=radius, center=center, n=64), cam, front)
    return out


def outline_circle(cam, center, radius, n=40):
    c = cam.project(center)
    return circle(c[0], c[1], radius * cam.scale, n=n)


# ---------------------------------------------------------------- Perspective & Form

def perspective():
    L = []
    road = Camera(center=(CX, 0.4), scale=0.3, dist=1.0, height=1.0)
    horizon = helper(line((0.03, 0.4), (ASPECT - 0.03, 0.4)), w=0.006)

    def rails():
        return [ink([road.project((x, 0, 0.45)), road.project((x, 0, -45))]) for x in (-0.55, 0.55)]

    def sleepers(shift=0.0):
        out = []
        for i in range(8):
            z = 0.45 - 1.0 * i + shift
            if z <= 0.46 and z > -9:
                out.append(ink([road.project((-0.7, 0, z)), road.project((0.7, 0, z))]))
        return out

    def poles(shift=0.0):
        out = []
        for i in range(8):
            z = 0.4 - 2.0 * i + shift
            if -16 < z <= 0.45:
                out.append(ink([road.project((1.6, 0, z)), road.project((1.6, 1.6, z))]))
        return out
    move_frames = [F(rails() + sleepers(k / 8 * 1.0) + poles(k / 8 * 1.0)) for k in range(8)]
    vp = road.project((0, 0, -1e6))
    L.append(lesson("persp.horizon", "The Horizon Line", "Eye level and the vanishing point.", [
        read("Your eye level",
             "The horizon line is always at your eye level. Lines that go straight away from you, like train tracks, "
             "all meet at one spot on the horizon called the vanishing point. Things get smaller the further away they are.",
             G(move_frames, bg=[horizon, dot(*vp)])),
        read("Above and below",
             "Look at a box below your eye level and you see its top. Lift it above your eye level and you see its "
             "bottom instead. Right on the horizon, you see neither.", G(_box_updown(), bg=[horizon_at(0.5)])),
        trace("Train tracks", "Trace the horizon, both rails and the sleepers. Every rail line heads to the vanishing point.",
              [ink(line((0.05, 0.4), (ASPECT - 0.05, 0.4)))] + rails() + sleepers(), bg=[dot(*vp)],
              hint="Use quick, straight pulls. Rails first, then the sleepers across them.", checks=[chk_straight()],
              tolerance=0.035),
        quiz("Where do train tracks seem to meet?", ["At the vanishing point on the horizon", "At the bottom of the page",
                                                     "They never get closer"], 0,
             "Parallel lines going away from you meet at the vanishing point."),
    ]))

    cam1 = Camera(center=(CX, 0.32), scale=0.22, dist=4.0)
    vis, hid = box_edges(cam1, center=(1.0, -1.1, -0.2), size=(1.2, 1.2, 1.2))
    vp1 = cam1.project((0, 0, -1e6))
    front = [cam1.project(p) for p in ((0.4, -0.5, 0.4), (1.6, -0.5, 0.4), (1.6, -1.7, 0.4), (0.4, -1.7, 0.4))]
    to_vp = [helper([c, vp1]) for c in front]
    hz = horizon_at(0.32)
    steps_ = [F([hz, dot(*vp1)], hold=10, notes=[("1. horizon + point", CX, 0.92)]),
              F([hz, dot(*vp1), ink(front, closed=True)], hold=10, notes=[("2. front square", CX, 0.92)]),
              F([hz, dot(*vp1), ink(front, closed=True)] + to_vp, hold=10, notes=[("3. lines to the point", CX, 0.92)]),
              F([hz, dot(*vp1)] + to_vp + [ink(e) for e in vis] + [helper(e) for e in hid], hold=16,
                notes=[("4. close the back", CX, 0.92)])]
    L.append(lesson("persp.onepoint", "One-Point Box", "A box with its front facing you.", [
        read("Box in one-point",
             "In one-point perspective, the front of the box faces you as a flat square. Its sides go back toward "
             "one vanishing point. Draw the front square, run lines from its corners to the point, then close the "
             "back where you want the box to end.", G(steps_)),
        trace("Your box", "Trace the box. The faint lines show where its edges head.",
              [ink(e) for e in vis], bg=[hz, dot(*vp1)] + to_vp,
              hint="Front square first, then the edges that go back, then the back edges.", checks=[chk_straight()]),
        quiz("In one-point perspective, the box's front face is...", ["A flat square facing you",
                                                                      "Tilted away on both sides"], 0,
             "Only the sides recede; the front stays square."),
    ]))

    cam2 = Camera(center=(CX, 0.3), scale=0.25, dist=3.0)
    yaw = math.radians(45)
    vis2, hid2 = box_edges(cam2, center=(0, -1.0, -0.6), size=(1.1, 1.1, 1.1), rot=(0, yaw, 0))
    vpa = vanishing_point(cam2, rot_y((1, 0, 0), yaw))
    vpb = vanishing_point(cam2, rot_y((0, 0, 1), yaw))
    top_pts = [cam2.project((rot_y((sx * 0.55, 0.55, sz * 0.55), yaw)[0], -1.0 + 0.55,
                             rot_y((sx * 0.55, 0.55, sz * 0.55), yaw)[2] - 0.6)) for sx in (-1, 1) for sz in (-1, 1)]
    near = max(top_pts, key=lambda p: p[1])
    guides2 = [helper([near, vpa]), helper([near, vpb]), horizon_at(0.3), dot(*vpa), dot(*vpb)]
    spin = []
    for k in range(12):
        v_, h_ = box_edges(cam2, center=(0, -1.0, -0.6), size=(1.1, 1.1, 1.1), rot=(0, math.radians(15 + 60 * k / 12), 0))
        spin.append(F([ink(e) for e in v_]))
    L.append(lesson("persp.twopoint", "Two-Point Box", "A box with a corner pointing at you.", [
        read("Corner first",
             "Turn the box so a corner points at you, and its sides now head to two vanishing points, one on each side "
             "of the horizon. Vertical edges stay straight up and down.", G(spin, bg=[horizon_at(0.3)])),
        trace("Two-point box", "Trace the box. Its top edges head toward the two dots on the horizon.",
              [ink(e) for e in vis2], bg=guides2, hint="Start with the front vertical edge, then the top edges.",
              checks=[chk_straight()]),
        quiz("A two-point box shows you...", ["A corner pointing at you, with sides going to two points", "One flat face"],
             0, "Each side heads to its own vanishing point."),
    ]))

    camc = Camera(center=(CX, 0.25), scale=0.17, dist=7.0)
    cyl_frames = []
    for k in range(16):
        y = -0.6 - 2.4 * (0.5 - 0.5 * math.cos(TAU * k / 16))
        cyl_frames.append(F(cylinder_paths(camc, (0.0, y, 0.0), 0.9, 1.0)))
    L.append(lesson("persp.cylinder", "Cylinders", "Two ellipses joined by straight sides.", [
        read("Ellipses change with eye level",
             "A cylinder is two ellipses joined by straight sides. An ellipse near your eye level looks thin and flat. "
             "The further below your eyes it goes, the rounder it gets. Watch the can sink below the horizon.",
             G(cyl_frames, bg=[horizon_at(0.25)])),
        trace("Draw a can", "Trace the can: a full ellipse on top, the front half of the bottom, and two straight sides.",
              cylinder_paths(camc, (0.0, -2.2, 0.0), 0.9, 1.6), bg=[horizon_at(0.25)],
              hint="The bottom curve is rounder than the top, because it's further below your eyes."),
        quiz("A cup far below your eye level: its top ellipse looks...", ["Rounder", "Flatter", "Like a straight line"], 0,
             "The further from eye level, the more you see into it, so it gets rounder."),
    ]))

    cams = Camera(center=(CX, 0.5), scale=0.34, ortho=True, pitch=math.radians(20))
    ball_frames = []
    for k in range(12):
        yaw_ = TAU * k / 12 / 4
        lines_ = sphere_lines(cams, yaw=yaw_, lats=(-0.7, 0.0, 0.7), lons=(0.0, math.pi / 4, math.pi / 2, 3 * math.pi / 4))
        ball_frames.append(F([ink(circle(CX, 0.5, 0.34, n=56), closed=True)] + [ink(l_) for l_ in lines_]))
    wrap = sphere_lines(cams, yaw=math.radians(30), lats=(0.0,), lons=(0.0,))
    L.append(lesson("persp.sphere", "Spheres", "Wrap lines around a ball to show its turn.", [
        read("Balls with lines",
             "A ball's outline is a circle from every side. To show which way it's turned, draw lines that wrap "
             "around it, like the equator and lines from pole to pole. The way they curve shows the angle.",
             G(ball_frames)),
        trace("Wrap a ball", "Trace the circle, then the two curved lines that wrap around it.",
              [ink(circle(CX, 0.5, 0.34, n=56), closed=True)] + [ink(l_) for l_ in wrap],
              hint="Draw the circle, then let each curve hug the ball.", checks=[chk_smooth()]),
        quiz("From any side, the outline of a ball is...", ["A circle", "A square", "A triangle"], 0,
             "That's why the wrapped lines are needed to show which way it faces."),
    ]))
    return course("perspective", TRACK, "Perspective & Form", "Boxes, cylinders and balls in space", "cube",
                  ["basics"], L)


def horizon_at(y):
    return helper(line((0.03, y), (ASPECT - 0.03, y)), w=0.006)


def _box_updown():
    cam = Camera(center=(CX, 0.5), scale=0.2, dist=6.0)
    out = []
    for k in range(16):
        y = 1.5 * math.sin(TAU * k / 16)
        v, h = box_edges(cam, center=(0.0, y, 0.0), size=(1.0, 1.0, 1.0), rot=(0, math.radians(30), 0))
        out.append(F([ink(e) for e in v]))
    return out


# ---------------------------------------------------------------- Turnarounds

LINE_HEIGHTS = (("top", 2.05), ("eyes", 1.6), ("chin", 1.05), ("feet", 0.0))


def buddy(yaw, cx, ground=0.9, s=0.38, construction=True):
    """A simple 3D character (ball head, egg body, feet, eyes, nose, ears) seen from the side at angle `yaw`."""
    cam = Camera(center=(cx, ground), scale=s, ortho=True)

    def R(p):
        return rot_y(p, yaw)
    paths = []
    head_c = (0.0, 1.55, 0.0)
    hr = 0.5
    paths.append(ink(outline_circle(cam, head_c, hr), closed=True))
    # body: an ellipsoid; its outline under a turn is an ellipse
    bx, by, bz = 0.42, 0.55, 0.32
    rx = math.hypot(bx * math.cos(yaw), bz * math.sin(yaw))
    bc = cam.project((0.0, 0.62, 0.0))
    paths.append(ink(ellipse(bc[0], bc[1], rx * s, by * s, n=44), closed=True))
    # feet
    for side in (-1, 1):
        fc = R((side * 0.2, 0.06, 0.12))
        frx = math.hypot(0.14 * math.cos(yaw), 0.24 * math.sin(yaw))
        p = cam.project(fc)
        paths.append(ink(ellipse(p[0], p[1], frx * s, 0.065 * s, n=24), closed=True))
    # eyes, nose, ears on the head ball (drawn only when on the near side)
    for side in (-1, 1):
        d = R((math.sin(side * 0.38) * math.cos(0.12), math.sin(0.12), math.cos(side * 0.38) * math.cos(0.12)))
        if d[2] > 0.05:
            c = cam.project((head_c[0] + d[0] * hr, head_c[1] + d[1] * hr, head_c[2] + d[2] * hr))
            paths.append(ink(ellipse(c[0], c[1], max(0.004, 0.07 * s * d[2]), 0.09 * s, n=16), closed=True))
        e = R((side * 1.0, 0.0, -0.05))
        if e[2] > -0.6:
            c = cam.project((head_c[0] + e[0] * hr, head_c[1] + e[1] * hr, head_c[2] + e[2] * hr))
            paths.append(ink(ellipse(c[0], c[1], max(0.01, 0.1 * s * abs(e[0])) + 0.012, 0.12 * s, n=16), closed=True))
    n = R((0.0, -0.15, 1.0))
    if n[2] > -0.2:
        c = cam.project((head_c[0] + n[0] * hr * 1.08, head_c[1] - 0.08, head_c[2] + n[2] * hr * 1.08))
        paths.append(ink(circle(c[0], c[1], 0.085 * s, n=14), closed=True))
    if construction:
        front = lambda p: cam.view((p[0] - head_c[0], p[1] - head_c[1], p[2] - head_c[2]))[2] > 0
        for run in visible_runs(sphere_circle(R, lon=0.0, radius=hr, center=head_c, n=48), cam, front):
            paths.append(helper(run))
    return paths


def guide_lines(ground=0.9, s=0.38, x0=0.03, x1=ASPECT - 0.03):
    return [helper(line((x0, ground - h * s), (x1, ground - h * s)), w=0.004) for _, h in LINE_HEIGHTS]


def turnarounds():
    L = []
    spin = [F(buddy(TAU * k / 16, CX)) for k in range(16)]
    views = [(0.0, "front"), (math.radians(45), "3/4"), (math.radians(90), "side"), (math.pi, "back")]
    sheet = []
    for i, (yw, name) in enumerate(views):
        sheet += buddy(yw, 0.19 + 0.32 * i, ground=0.85, s=0.24)
    sheet_notes = [(name, 0.19 + 0.32 * i, 0.94) for i, (_, name) in enumerate(views)]
    L.append(lesson("turn.why", "What's a Turnaround?", "One character, seen from every side.", [
        read("Same character, every side",
             "A turnaround is a set of drawings of one character from different sides: front, three-quarter, side "
             "and back. Animators use it so the character looks the same in every scene, from every angle.",
             G(spin, bg=guide_lines())),
        read("Line it all up",
             "Draw the views side by side and run straight lines across: the top of the head, the eyes, the chin and "
             "the feet. Every view must touch the same lines, so the character never grows or shrinks.",
             still(sheet, bg=guide_lines(0.85, 0.24), notes=sheet_notes)),
        quiz("Why run lines across a turnaround?", ["So every view is the same height", "To color it faster",
                                                    "They're the ground"], 0,
             "Matching heights keeps the character the same size from every side."),
    ]))

    fs = []
    for k in range(4):
        fs.append(F(buddy(0.0 if k % 2 == 0 else math.pi / 2, CX), hold=14,
                    notes=[("front" if k % 2 == 0 else "side", 0.2, 0.08)]))
    L.append(lesson("turn.frontside", "Front & Side", "The two easiest views.", [
        read("Front and side",
             "Start with the front view. Then draw the side view using the same guide lines, so the eyes, chin and "
             "feet sit at the same heights. In the side view the nose sticks out past the head, and you only see one eye.",
             G(fs, bg=guide_lines())),
        trace("Front view", "Trace the front view: head, eyes, nose, ears, body and feet.", buddy(0.0, CX),
              bg=guide_lines(), hint="Biggest shapes first: head and body. Then the small parts.", tolerance=0.04),
        trace("Side view", "Trace the side view. Check the eye sits on the same line as before.", buddy(math.pi / 2, CX),
              bg=guide_lines(), hint="The nose pokes out past the circle of the head.", tolerance=0.04),
        quiz("In a side view, how many eyes can you usually see?", ["One", "Two", "None"], 0,
             "The other eye is hidden around the far side of the head."),
    ]))

    tq = [F(buddy(math.radians(90) * (0.5 - 0.5 * math.cos(TAU * k / 16)), CX)) for k in range(16)]
    L.append(lesson("turn.threequarter", "The 3/4 View", "Halfway between front and side.", [
        read("Halfway round",
             "The three-quarter view is halfway between front and side. The face slides toward one side: the "
             "center line (the dashed line) curves around the head, the far eye looks thinner, and the far ear hides.",
             G(tq, bg=guide_lines())),
        trace("3/4 view", "Trace the three-quarter view. Notice the far eye is narrower.", buddy(math.radians(45), CX),
              bg=guide_lines(), hint="Use the dashed center line to place the nose.", tolerance=0.04),
        quiz("In a 3/4 view, the far eye looks...", ["Narrower than the near eye", "Bigger than the near eye",
                                                     "Exactly the same"], 0,
             "It's turning away from you around the ball of the head."),
    ]))

    fb = [F(buddy(0.0 if k % 2 == 0 else math.pi, CX), hold=14, notes=[("front" if k % 2 == 0 else "back", 0.2, 0.08)])
          for k in range(4)]
    four = [F(buddy(yw, CX, construction=False)) for yw, _ in views]
    L.append(lesson("turn.back", "Back View & Full Sheet", "Finish the turnaround.", [
        read("Back view",
             "The back view has the same outline as the front, but no face. Check that it touches the same guide "
             "lines as the other views.", G(fb, bg=guide_lines())),
        frames("Draw the turnaround", "Draw all four views, one per frame: front, 3/4, side and back.", four,
               bg=guide_lines(), hint="Keep the head on the top line and the feet on the bottom line every time.",
               fps=2, loop=False, tolerance=0.045),
        quiz("The back view's outline matches...", ["The front view, without a face", "The side view", "Nothing else"], 0,
             "From behind, the head and body have the same outline as from the front."),
    ]))
    return course("turnarounds", TRACK, "Turnarounds", "Front, 3/4, side and back views", "person.crop.rectangle.stack",
                  ["perspective"], L)


# ---------------------------------------------------------------- Rotating Objects

def rotating():
    L = []
    cam = Camera(center=(CX, 0.55), scale=0.26, dist=5.0, pitch=math.radians(25))
    size = 1.3
    track = [cam.project(p) for p in circle3d((0, size / 2, 0), size / math.sqrt(2), n=64)]
    track_b = [cam.project(p) for p in circle3d((0, -size / 2, 0), size / math.sqrt(2), n=64)]

    def cube(yaw):
        v, h = box_edges(cam, size=(size, size, size), rot=(0, yaw, 0))
        return [ink(e) for e in v]
    spin = [F(cube(math.radians(90 * k / 12))) for k in range(12)]
    L.append(lesson("rot.cube", "Spinning Cube", "Corners travel around ellipses.", [
        read("Corners travel on ellipses",
             "When a cube spins, each corner travels around a circle. Seen from above at an angle, that circle "
             "looks like an ellipse (the orange lines). Draw the ellipse first, then place the corners on it for "
             "each frame.", G(spin, bg=[accent(track), accent(track_b)])),
        frames("Spin the cube", "Draw the cube turning a little more on each frame. Frame 4 leads back into frame 1.",
               [F(cube(math.radians(22.5 * k))) for k in range(4)], bg=[accent(track), accent(track_b)],
               hint="Slide each top corner a little further along the orange ellipse.", checks=[chk_loop()], fps=6,
               tolerance=0.045),
        quiz("As a cube spins, its top corners move along...", ["An ellipse", "A straight line", "A zigzag"], 0,
             "Each corner goes round in a circle, which looks like an ellipse at an angle."),
    ]))

    camc = Camera(center=(CX, 0.5), scale=0.24, dist=6.0, pitch=math.radians(20))
    can = cylinder_paths(camc, (0, 0, 0), 1.0, 2.0)
    can_bg = [dict(p, role="guide") for p in can]

    def stripe(phi):
        return [camc.project((math.sin(phi), y, math.cos(phi))) for y in (-1.0, -0.5, 0.0, 0.5, 1.0)]
    spin_c = []
    for k in range(16):
        phi = -math.pi / 2 + math.pi * k / 16 + 0.01
        spin_c.append(F([ink(stripe(phi))]))
    L.append(lesson("rot.cylinder", "Spinning Can", "The outline stays, the label slides.", [
        read("The label slides",
             "When a can spins, its outline doesn't change at all. Only the things on it move: a stripe slides "
             "across, fast in the middle and slow near the edges, because it's going around the curve.",
             G(spin_c, bg=can_bg)),
        frames("Slide the stripe", "Draw the stripe on each frame as it comes round the can.",
               [F([ink(stripe(math.radians(a)))]) for a in (-72, -36, 0, 36, 72)], bg=can_bg,
               hint="Small gaps near the edges, big gaps in the middle.", checks=[chk_spacing("easeInOut")], fps=5,
               loop=False),
        quiz("Where does the stripe move fastest across the can?", ["In the middle", "At the edges"], 0,
             "In the middle it's moving straight across; at the edges it's moving mostly toward or away from you."),
    ]))

    R = 0.17

    def coin(cx, cy, theta):
        ry = max(0.012, R * abs(math.cos(theta)))
        out = [ink(ellipse(cx, cy, R, ry, n=40), closed=True)]
        if ry > 0.05:
            out.append(ink(ellipse(cx, cy, R * 0.75, ry * 0.75, n=32), closed=True))
        return out
    flip = []
    g = 0.012
    v = -0.13
    y = 0.8
    for k in range(22):
        flip.append(F(coin(CX, y, math.pi * k / 5.5)))
        v += g
        y += v
        if y > 0.8:
            break
    L.append(lesson("rot.coin", "Coin Flip", "Circle, ellipse, line and back.", [
        read("Flip!",
             "A flipping coin turns from a full circle into a thinner and thinner ellipse, then a thin line when it's "
             "edge-on, then back again. Gravity brings it up and down at the same time.", G(flip)),
        frames("Coin shapes", "Draw the coin as it turns away: a circle, an ellipse, a thin ellipse, then edge-on.",
               [F(coin(CX, 0.5, math.radians(a))) for a in (0, 45, 72, 90)],
               hint="The width stays the same; only the height shrinks.", fps=4, loop=False),
        quiz("When the coin is edge-on to you, it looks like...", ["A thin line", "A full circle"], 0,
             "You're looking at its thin edge."),
    ]))

    def wheel(cx, cy, r, angle, spokes=6):
        out = [ink(circle(cx, cy, r, n=48), closed=True), ink(circle(cx, cy, r * 0.14, n=16), closed=True)]
        for i in range(spokes):
            a = angle + TAU * i / spokes
            out.append(ink([(cx + r * 0.14 * math.cos(a), cy + r * 0.14 * math.sin(a)),
                            (cx + r * math.cos(a), cy + r * math.sin(a))]))
        return out
    trick = [F(wheel(0.38, 0.5, 0.24, math.radians(8 * k)) + wheel(0.98, 0.5, 0.24, math.radians(55 * k)),
               notes=[("8 degrees a frame", 0.38, 0.86), ("55 degrees a frame", 0.98, 0.86)]) for k in range(15)]
    L.append(lesson("rot.wheel", "Wheels", "Spokes and the backward-wheel trick.", [
        read("The backward-wheel trick",
             "A spinning wheel looks great until it's too fast. These spokes are 60 degrees apart. The right wheel "
             "turns 55 degrees each frame, almost a whole gap, so your eyes think it's going slowly backward! Keep "
             "each frame's turn to less than half the gap between spokes, or blur the spokes.", G(trick)),
        trace("Draw the wheel", "Trace the rim, the hub and the six spokes.", wheel(CX, 0.5, 0.38, 0.0),
              hint="Circles first, then the spokes from the hub out.", tolerance=0.04),
        frames("Turn the wheel", "Draw the wheel turning a quarter of a gap each frame.",
               [F(wheel(CX, 0.5, 0.38, math.radians(15 * k))) for k in range(3)],
               hint="Each spoke moves only a little way round.", fps=4, loop=False, tolerance=0.04),
        quiz("To stop a wheel looking like it spins backward, each frame should turn it...",
             ["Less than half the gap between spokes", "Almost a full gap between spokes"], 0,
             "Small turns read as forward motion."),
    ]))
    return course("rotating", TRACK, "Rotating Objects", "Cubes, cans, coins and wheels", "rotate.3d",
                  ["perspective"], L)


def p_pts(p):
    f = p["pts"]
    return [(f[i], f[i + 1]) for i in range(0, len(f), 2)]


# ---------------------------------------------------------------- Camera Moves

def scene(shift):
    paths = [helper(mountains(0.03, ASPECT - 0.03, 0.62, 0.3, phase=shift * 0.3, period=0.9))]
    for x in (0.3, 0.9, 1.5, 2.1):
        xx = x - shift
        if 0.08 < xx < ASPECT - 0.08:
            paths += tree(xx, 0.86, h=0.34, w=0.18)
    return paths


def camera():
    L = []
    pan = []
    for k in range(20):
        t = min(1.0, k / 12)
        pan.append(F(scene(0.8 * ease_in_out(t)), hold=8 if k == 19 else 1))
    strip_bg = [helper(rect(0.05, 0.25, ASPECT - 0.05, 0.6), closed=True)]
    strip = []
    for k in range(16):
        x = 0.05 + 0.58 * (0.5 - 0.5 * math.cos(TAU * k / 16))
        pts = []
        for i in range(60):
            xx = 0.05 + (ASPECT - 0.1) * i / 59
            pts.append((xx, 0.55 - 0.12 * (0.5 + 0.3 * math.sin(xx * 9) + 0.2 * math.sin(xx * 23))))
        strip.append(F([ink(pts), accent(rect(x, 0.22, x + 0.6, 0.63), closed=True)],
                       notes=[("what the camera sees", x + 0.3, 0.7)]))
    tx = [1.0 - 0.6 * ease_in_out(k / 3) for k in range(4)]
    L.append(lesson("cam.pan", "Pan", "Slide the camera sideways.", [
        read("Slide across",
             "A pan is when the camera slides sideways, like turning your head to look across a room. Everything in "
             "the picture slides the other way. Start and stop gently (ease in and ease out) so it's not jerky.",
             G(pan, bg=[helper(line((0.03, 0.86), (ASPECT - 0.03, 0.86)))])),
        read("Long backgrounds",
             "For a pan, draw a background much wider than the screen, then slide it a little each frame. The orange "
             "box is what the camera sees.", G(strip, bg=strip_bg)),
        frames("Pan past a tree", "The camera pans right, so the tree slides left. Ease in and out: small, big, small gaps.",
               [F(tree(x, 0.86, h=0.5, w=0.28)) for x in tx], hint="Small gap, big gap, small gap.",
               checks=[chk_spacing("easeInOut")], fps=6, loop=False),
        quiz("When the camera pans right, the background moves...", ["Left", "Right", "Up"], 0,
             "The camera moves one way, so the picture slides the other way."),
    ]))

    par = []
    n = 36
    for k in range(n):
        far_shift = 0.01 * k
        mid_shift = 0.02 * k
        near_shift = 0.04 * k
        paths = [helper(mountains(0.03, ASPECT - 0.03, 0.55, 0.25, phase=far_shift, period=0.36 * 2))]
        for i in range(-1, 6):
            x = 0.2 + 0.36 * i - (mid_shift % 0.36)
            if 0.08 < x < ASPECT - 0.08:
                paths += tree(x, 0.72, h=0.22, w=0.12)
        for i in range(-1, 8):
            x = 0.1 + 0.24 * i - (near_shift % 0.24)
            if 0.03 < x < ASPECT - 0.03:
                paths.append(ink([(x, 0.98), (x, 0.8)], w=0.02))
        paths.append(ink([(0.03, 0.86), (ASPECT - 0.03, 0.86)], w=0.014))
        par.append(F(paths))
    L.append(lesson("cam.parallax", "Parallax", "Near is fast, far is slow.", [
        read("Near is fast, far is slow",
             "When the camera moves sideways, things close to it zoom past while far things barely move. This is "
             "parallax, and it makes a flat drawing feel deep. Here the fence moves 4 times as fast as the mountains, "
             "and the trees twice as fast.", G(par)),
        tool("Parallax with layers", "Put each depth on its own layer.", "layers", [
            "Draw the mountains on a Back layer, trees on a Middle layer, and a fence on a Front layer.",
            "On each new frame, move the Front layer a lot, the Middle a little, and the Back just a tiny bit.",
            "Play it back. Does it feel deep?",
        ]),
        quiz("Which layer moves fastest in a parallax shot?", ["The one closest to the camera", "The one furthest away",
                                                               "They all move the same"], 0,
             "Near things cross your view quickly; far things take ages."),
        quiz("The fence moves 4 steps each frame and the trees move 2. How far should the far mountains move?",
             ["1 step", "8 steps", "4 steps"], 0, "Further away means slower, so the mountains move the least."),
    ]))

    def orbit_scene(yaw, pillars=True):
        cam = Camera(center=(CX, 0.42), scale=0.2, dist=8.0, pitch=math.radians(25), yaw=yaw)
        paths = []
        for i in range(-3, 4):
            paths.append(helper([cam.project((i * 0.8, -1.0, -2.4)), cam.project((i * 0.8, -1.0, 2.4))]))
            paths.append(helper([cam.project((-2.4, -1.0, i * 0.8)), cam.project((2.4, -1.0, i * 0.8))]))
        v, h = box_edges(cam, center=(0, -0.4, 0), size=(1.2, 1.2, 1.2))
        paths += [ink(e) for e in v]
        if pillars:
            for z in (1.8, -1.8):
                v2, h2 = box_edges(cam, center=(1.2 if z > 0 else -1.2, -0.5, z), size=(0.3, 1.0, 0.3))
                paths += [ink(e) for e in v2]
        return paths
    orbit = [F(orbit_scene(math.radians(60 * math.sin(TAU * k / 24)))) for k in range(24)]
    L.append(lesson("cam.orbit", "Orbit", "Circle the camera around the subject.", [
        read("Circling around",
             "In an orbit, the camera circles around the subject. Things in front of the subject slide one way, and "
             "things behind it slide the other way. It's tricky to draw by hand, so keep shapes simple: boxes and "
             "cylinders on a ground grid.", G(orbit)),
        frames("Orbit a box", "Draw the box as the camera moves around it.",
               [F([p for p in orbit_scene(math.radians(a), pillars=False) if p.get("role", "ink") == "ink"],)
                for a in (0, 20, 40)],
               bg=[p for p in orbit_scene(0.0, pillars=False) if p.get("role") == "guide"],
               hint="The front corner moves across a little each frame.", fps=4, loop=False, tolerance=0.045),
        quiz("When the camera orbits around a statue, things behind the statue...",
             ["Slide the opposite way to things in front", "Don't move", "Get bigger"], 0,
             "The camera swings around the middle, so front and back move in opposite directions."),
    ]))

    def zoom_scene(cx, focal=1.0, dist_=8.0):
        cam = Camera(center=(cx, 0.5), scale=0.12 * focal, dist=dist_)
        paths = [helper(rect(cx - 0.3, 0.2, cx + 0.3, 0.8), closed=True)]
        v, h = box_edges(cam, center=(-0.9, -0.6, 0.0), size=(0.8, 0.8, 0.8))
        paths += [ink(e) for e in v]
        v2, h2 = box_edges(cam, center=(2.5, 0.6, -16.0), size=(3.0, 3.0, 3.0))
        paths += [ink(e) for e in v2]
        return paths
    zf = []
    for k in range(16):
        t = 0.5 - 0.5 * math.cos(TAU * k / 16)
        zoom_f = 1.0 + 0.7 * t
        zf.append(F(zoom_scene(0.35, focal=zoom_f, dist_=8.0) +
                    zoom_scene(1.0, focal=8.0 / (8.0 - 3.5 * t), dist_=8.0 - 3.5 * t),
                    notes=[("zoom", 0.35, 0.12), ("push in", 1.0, 0.12)]))
    sun = []
    for k in range(3):
        r = 0.1 + 0.07 * k
        paths = [ink(circle(CX, 0.5, r, n=40), closed=True)]
        for i in range(8):
            a = TAU * i / 8
            paths.append(ink([(CX + (r + 0.03) * math.cos(a), 0.5 + (r + 0.03) * math.sin(a)),
                              (CX + (r * 1.6 + 0.03) * math.cos(a), 0.5 + (r * 1.6 + 0.03) * math.sin(a))]))
        sun.append(F(paths))
    L.append(lesson("cam.zoom", "Zoom & Push In", "Two ways to get closer.", [
        read("Zoom vs push in",
             "A zoom makes everything bigger together, like a magnifying glass. A push in moves the camera closer: "
             "the near box grows fast while the far box hardly changes. A push in feels like walking into the scene.",
             G(zf)),
        frames("Zoom in on the sun", "Draw the sun getting bigger on each frame, staying in the middle.", sun,
               hint="The middle stays put; everything grows outward.", fps=4, loop=False, tolerance=0.045),
        quiz("In a push in, which things get bigger fastest?", ["Things near the camera", "Things far away",
                                                                 "Everything the same"], 0,
             "Moving closer changes near things a lot and far things only a little."),
    ]))
    return course("camera", TRACK, "Camera Moves", "Pan, parallax, orbit and zoom", "video", ["rotating"], L)


# ---------------------------------------------------------------- 3D Characters in 2D

def head(yaw=0.0, pitch=0.0, cx=CX, cy=0.42, s=0.28, jaw=True, ink_lines=True):
    """A construction head: a ball, the center line and eye line wrapping around it, and the jaw."""
    cam = Camera(center=(cx, cy), scale=s, ortho=True)

    def R(p):
        return rot_x(rot_y(p, yaw), pitch)
    paths = [ink(circle(cx, cy, s, n=56), closed=True)]
    front = lambda p: cam.view(p)[2] > 0
    mk = ink if ink_lines else helper
    for run in visible_runs(sphere_circle(R, lon=0.0, n=72), cam, front):
        paths.append(mk(run))
    for run in visible_runs(sphere_circle(R, lat=0.0, n=96), cam, front):
        paths.append(mk(run))
    if jaw:
        l_ = R((-0.82, -0.25, 0.3))
        r_ = R((0.82, -0.25, 0.3))
        chin = R((0.0, -1.35, 0.45))
        mid_l = R((-0.55, -0.95, 0.45))
        mid_r = R((0.55, -0.95, 0.45))
        pts = [cam.project(p) for p in (l_, mid_l, chin, mid_r, r_)]
        paths.append(ink(catmull(pts, per=6)))
    return paths


def characters():
    L = []
    build = []
    full = head(math.radians(25), math.radians(-8))
    parts = [full[:1], full[:2], full[:3], full]
    names = ["1. a ball", "2. center line", "3. eye line", "4. jaw and chin"]
    for p, n in zip(parts, names):
        build.append(F(p, hold=12, notes=[(n, CX, 0.92)]))
    L.append(lesson("char.head", "Build a Head", "A ball, two lines and a jaw.", [
        read("Ball and jaw",
             "Start a head with a ball. Draw a line down the middle of the face (the center line) and a line across "
             "where the eyes go (the eye line). Both lines wrap around the ball. Then hang the jaw and chin below.",
             G(build)),
        trace("Construct a head", "Trace the ball, the two wrapping lines and the jaw.", full,
              hint="Ball first. Then the curved center line, then the eye line, then the jaw.", tolerance=0.045),
        quiz("What are the two lines that wrap around the head ball?", ["The center line and the eye line",
                                                                        "The horizon and the ground", "Speed lines"], 0,
             "They show which way the face is pointing."),
    ]))

    turn = [F(head(math.radians(80) * math.sin(TAU * k / 20))) for k in range(20)]
    L.append(lesson("char.turn", "Head Turns", "The center line slides around the ball.", [
        read("Turning the head",
             "As the head turns, the center line slides across the ball as a curve, and the face rides along with it. "
             "Turned all the way to the side, the center line sits right at the edge of the ball.", G(turn)),
        frames("Front to side", "Draw the head turning: front, three-quarter, then side.",
               [F(head(math.radians(a))) for a in (0, 45, 85)], hint="Watch the center line curve more and more.",
               fps=3, loop=False, tolerance=0.045),
        quiz("When the head turns to the side, the center line...", ["Curves around the ball toward the edge",
                                                                      "Stays straight in the middle"], 0,
             "It's drawn on the surface of the ball, so it follows the curve."),
    ]))

    nod = [F(head(0.0, math.radians(30) * math.sin(TAU * k / 16), jaw=False)) for k in range(16)]
    up = head(math.radians(10), math.radians(-28), jaw=False)
    down = head(math.radians(10), math.radians(28), jaw=False)
    L.append(lesson("char.updown", "Looking Up & Down", "The eye line bends.", [
        read("Looking up and down",
             "When a head tilts up, the eye line bends upward in the middle like a rainbow. When it tilts down, the eye "
             "line bends downward like a smile, and you see more of the top of the head.", G(nod)),
        trace("Looking up", "Trace the head looking up. The eye line arches like a rainbow.", up,
              hint="Ball first, then the arched eye line.", tolerance=0.045),
        trace("Looking down", "Trace the head looking down. The eye line dips like a smile.", down,
              hint="Ball first, then the dipping eye line.", tolerance=0.045),
        quiz("When a character looks down, the eye line curves like...", ["A smile", "A rainbow", "A straight line"], 0,
             "Tilting down rolls the middle of the line downward."),
    ]))

    cam = Camera(center=(CX, 0.25), scale=0.22, dist=3.2)

    def arm(a):
        sh = (0.0, 0.9, 0.0)
        d = (0.0, -math.cos(a), math.sin(a))
        el = (sh[0] + 1.0 * d[0], sh[1] + 1.0 * d[1], sh[2] + 1.0 * d[2])
        fi = (sh[0] + 1.9 * d[0], sh[1] + 1.9 * d[1], sh[2] + 1.9 * d[2])
        out = []
        cs = []
        for p, r in ((sh, 0.28), (el, 0.22), (fi, 0.3)):
            c = cam.project(p)
            k = cam.scale * cam.dist / max(0.05, cam.dist - p[2])
            cs.append((c, r * k))
            out.append(ink(circle(c[0], c[1], r * k, n=36), closed=True))
        for (c1, r1), (c2, r2) in zip(cs, cs[1:]):
            for t in tangents(c1, r1, c2, r2):
                out.append(ink(t))
        return out
    reach = [F(arm(math.radians(70) * (0.5 - 0.5 * math.cos(TAU * k / 16)))) for k in range(16)]
    L.append(lesson("char.foreshort", "Foreshortening", "Things pointing at you look shorter.", [
        read("Pointing at you",
             "Foreshortening happens when something points toward you. An arm reaching at the camera looks shorter, "
             "and the hand looks much bigger because it's closer. Draw it as overlapping circles: a big one for the "
             "hand, smaller ones going back to the shoulder.", G(reach)),
        trace("Reaching arm", "Trace the arm reaching toward you: three circles joined by straight sides.",
              arm(math.radians(50)), hint="Draw the big hand circle first. It overlaps the others.", tolerance=0.045),
        quiz("An arm pointing straight at you looks...", ["Shorter, with a bigger hand", "Longer and thinner",
                                                          "The same as always"], 0,
             "The length is squashed and the near hand is bigger."),
    ]))
    return course("characters3d", TRACK, "3D Characters in 2D", "Head turns and foreshortening", "person.crop.circle",
                  ["turnarounds", "rotating"], L)


def tangents(c1, r1, c2, r2):
    """The two outside lines touching both circles (none when one circle hides inside the other)."""
    dx, dy = c2[0] - c1[0], c2[1] - c1[1]
    d = math.hypot(dx, dy)
    if d <= abs(r1 - r2) + 1e-6 or d < 1e-6:
        return []
    base = math.atan2(dy, dx)
    off = math.acos((r1 - r2) / d)
    out = []
    for sgn in (1, -1):
        a = base + sgn * off
        p1 = (c1[0] + r1 * math.cos(a), c1[1] + r1 * math.sin(a))
        p2 = (c2[0] + r2 * math.cos(a), c2[1] + r2 * math.sin(a))
        if dist(p1, p2) > 0.02:
            out.append([p1, p2])
    return out
