"""Track "2D Animation": More Bounces, Walk, Run and Effects (plus the ponytail sim hair lessons use)."""
import math

from learn_geo import (ASPECT, GROUND, TAU, arc, catmull, circle, dist, ease_in, ease_in_out, ease_out, ellipse,
                       lerp, lerp2, limb, line, move, rect, rotate, scale, sine_wave, spring_follow, star, walk_pose)
from learn_dsl import (F, G, accent, chk_closed, chk_loop, chk_smooth, chk_spacing, course, frames, helper, ink,
                       lesson, quiz, read, still, tool, trace)
from content_kit import (BALL_R, CX, MOUTH_WORDS, MOUTHS, ball, bean, cloud_puff, dot, eye, face, figure,
                         ghost_ball, ground, mouth)
from courses_principles import ink_squash, vertical_bounce

TRACK = "animation"
FLOOR = GROUND
BC = FLOOR - BALL_R  # ball centre when it rests on the floor


def bounce_path(x0, y0, vx, g, e, steps, floor=BC):
    """Ball centre positions frame by frame: gravity pulls it down, each hit keeps `e` of its speed."""
    x, y, vy = x0, y0, 0.0
    out = []
    for _ in range(steps):
        out.append((x, y))
        vy += g
        y += vy
        x += vx
        if y > floor:
            y = floor - (y - floor) * e
            vy = -vy * e
    return out


# ---------------------------------------------------------------- Bouncing Ball

def ball_course():
    L = []
    decay = bounce_path(0.1, 0.12, 0.034, 0.012, 0.72, 34)
    decay_frames = [F([ball(x, y, r=0.05)] + ([accent(decay[:k + 1])] if k else []), hold=8 if k == 33 else 1)
                    for k, (x, y) in enumerate(decay)]
    path_line = bounce_path(0.1, 0.12, 0.034 / 3, 0.012 / 9, 0.72, 100)
    L.append(lesson("ball.energy", "Losing Energy", "Each bounce is lower than the last.", [
        read("Smaller and smaller",
             "A real ball loses a little energy every time it hits the ground, so each bounce is lower and "
             "shorter than the one before, until it rolls to a stop.", G(decay_frames, bg=[ground(FLOOR - 0.02)])),
        trace("Trace the bounce path", "Trace the path the ball takes. Each hump is lower than the last.", [ink(path_line)],
              bg=[ground(FLOOR - 0.02)], hint="Go over the humps one at a time, touching the ground between them."),
        quiz("Each bounce should be...", ["Lower and shorter than the one before", "Higher than the one before",
                                          "Exactly the same"], 0, "The ball loses energy each time it lands."),
        quiz("Why do the bounces get lower?", ["The ball loses some energy every time it hits", "Gravity gets stronger",
                                               "The ball gets heavier"], 0,
             "Some energy turns into sound and squish each time it hits the ground."),
    ]))

    heavy = bounce_path(0.4, 0.15, 0.0, 0.016, 0.18, 24)
    light = []
    y, vy = 0.15, 0.0
    for _ in range(24):
        light.append((0.95, y))
        vy = vy * 0.9 + 0.006   # air slows a light ball down
        y += vy
        if y > BC - 0.02:
            y = BC - 0.02
            vy = -abs(vy) * 0.85
    hl = []
    for k in range(24):
        hx, hy = heavy[k]
        lx, ly = light[k]
        sq = 0.75 if ly >= BC - 0.025 else 1.0
        hl.append(F([ball(hx, hy, r=0.09, w=0.022), ball(lx, ly, r=0.09, stretch=1 / sq, angle=0.0, w=0.008)],
                    notes=[("bowling ball", 0.4, 0.06), ("beach ball", 0.95, 0.06)]))
    hl[-1]["hold"] = 10
    fall4 = [0.15 + (BC - 0.02 - 0.15) * (k / 3) ** 2 for k in range(4)]
    L.append(lesson("ball.weight", "Heavy or Light", "Timing and squash show weight.", [
        read("Heavy or light?",
             "A heavy bowling ball drops hard, hardly bounces and doesn't squash. A light beach ball drifts "
             "down, squashes a lot and bounces high and slow. Same shape, different weight, all shown with timing.",
             G(hl, bg=[ground()])),
        quiz("Which ball is the heavy bowling ball?", ["The left ball", "The right ball"], 0,
             "It falls hard, lands with a thud and barely bounces.", guide=G(hl, bg=[ground()])),
        frames("Heavy drop", "Draw the bowling ball falling fast. The gaps grow quickly.",
               [F([ball(CX, y, r=0.09)]) for y in fall4], bg=[ground()], checks=[chk_spacing("easeIn")], fps=6,
               loop=False, hint="Small gap, bigger gap, biggest gap."),
        quiz("A light beach ball should...", ["Bounce high and float down slowly", "Hit hard and barely bounce",
                                              "Not move at all"], 0, "Air slows light things down, so they float."),
    ]))
    return course("ball", TRACK, "More Bounces", "Losing energy, heavy and light", "circle.circle", ["pro"], L)


# ---------------------------------------------------------------- Walk and Run

POSE_NAMES = {2: "Contact", 3: "Down", 4: "Passing", 5: "Up", 6: "Contact", 7: "Down", 0: "Passing", 1: "Up"}
LEGS = ("far_leg", "near_leg")


def walk_frames(n, run=False, parts=None, notes=False, roles=None, hip_x=CX, size=0.62):
    out = []
    for k in range(n):
        pose = walk_pose(k / n, run=run, hip_x=hip_x, size=size)
        nts = [(POSE_NAMES[k * 8 // n], hip_x, 0.1)] if notes and (k * 8) % n == 0 else None
        out.append(F(figure(pose, parts=parts or ("far_leg", "far_arm", "torso", "near_leg", "near_arm", "head"),
                            roles=roles), notes=nts))
    return out


def stance_speed(run=False, size=0.62):
    """How far the hips move forward per cycle so the standing foot stays planted."""
    a = walk_pose(0.3, run=run, size=size)["near_leg"][2][0]
    b = walk_pose(0.7, run=run, size=size)["near_leg"][2][0]
    return (a - b) / 0.4


def walk(course_id="walk"):
    L = []
    cyc = walk_frames(8, notes=True)
    L.append(lesson("walk.poses", "The Four Poses", "Contact, down, passing and up.", [
        read("Four key poses",
             "Every walk step has four key poses. Contact: legs spread wide, both feet on the ground. Down: the front "
             "knee bends to catch the weight, so the body sinks. Passing: one leg swings past the other. Up: the back "
             "foot pushes off, so the body rises.", G(cyc, fps=4, bg=[ground()])),
        read("A cycle is two steps",
             "A full walk cycle is two steps: one with each foot. The second step uses the same four poses with the "
             "legs swapped. A normal walk takes about one second per cycle: 12 frames at 12 frames per second.",
             G(walk_frames(12, roles={"near_leg": "accent"}), fps=12, bg=[ground()])),
        trace("Contact pose", "Trace the contact pose: legs wide apart, arms swinging the opposite way.",
              figure(walk_pose(2 / 8)), bg=[ground()], hint="Draw the body line and head, then each leg, then each arm."),
        trace("Passing pose", "Trace the passing pose: one leg straight under the body, the other swinging past.",
              figure(walk_pose(0.0)), bg=[ground()], hint="The swinging leg's knee is bent and its foot is off the ground."),
        quiz("In the contact pose...", ["Both feet touch the ground, legs spread wide", "One leg passes the other",
                                        "Both feet are in the air"], 0, "Contact is where the front heel lands."),
    ]))

    legs8 = walk_frames(8, parts=LEGS)
    hip_path = [walk_pose(k / 32)["hip"] for k in range(33)]
    L.append(lesson("walk.legs", "Legs First", "Animate the legs, then add the rest.", [
        read("Start with the legs",
             "The legs carry the walk, so animate them first. Get the feet planted on the ground and the hips "
             "moving up and down a little. Arms, head and the rest come after.",
             G(walk_frames(8, parts=LEGS), fps=8, bg=[ground()])),
        frames("Leg cycle", "Draw the legs for all 8 frames. Frame 8 leads back into frame 1.", legs8, bg=[ground()],
               hint="The foot on the ground slides back a little each frame, like on a treadmill.", checks=[chk_loop()], fps=8, tolerance=0.04),
        quiz("When is the body highest in a walk?",
             ["When the standing leg is straight and the back foot pushes off", "When the legs are spread widest",
              "It stays at the same height"], 0, "A straight leg under the body lifts the hips highest."),
    ]))

    contact = walk_pose(2 / 8)
    L.append(lesson("walk.arms", "Swinging Arms", "Arms swing opposite to the legs.", [
        read("Arms swing opposite",
             "When the left leg goes forward, the right arm goes forward. This balances the body. Try it: walk "
             "around and watch your arms! The orange arm and leg are on the same side, so they always swing opposite.",
             G(walk_frames(12, roles={"near_arm": "accent", "near_leg": "accent"}), fps=12, bg=[ground()])),
        trace("Arms at contact", "Trace the contact pose and check the arms: each one goes the opposite way to its leg.",
              figure(contact), bg=[ground()], hint="The arm on the same side as the front leg swings back."),
        quiz("When your right leg steps forward, which arm swings forward?", ["Your left arm", "Your right arm", "Neither"],
             0, "Opposite arm, opposite leg: it keeps you balanced."),
    ]))

    v = stance_speed(size=0.45)
    across = []
    heads = []
    for k in range(17):
        ph = k / 8
        pose = walk_pose(ph % 1.0, hip_x=0.22 + v * ph, size=0.45)
        heads.append(pose["head_center"])
        across.append(F(figure(pose) + ([accent(list(heads))] if len(heads) > 1 else [])))
    bob = []
    for k in range(65):
        ph = k / 32
        pose = walk_pose(ph % 1.0, hip_x=0.22 + v * ph, size=0.45)
        bob.append(pose["head_center"])
    L.append(lesson("walk.bounce", "Up and Down", "The head bobs as you walk.", [
        read("The bob",
             "Your body goes down and up with every step. Watch the orange line: the path of the head makes a gentle "
             "wave as the character walks across.", G(across, fps=8, bg=[ground()])),
        trace("Trace the head path", "Trace the wave the head makes over two full cycles.", [ink(bob)],
              hint="Keep it smooth: small, even bumps.", checks=[chk_smooth()]),
        quiz("How many times does the head go down and up in one walk cycle (two steps)?", ["Once", "Twice", "Never"], 1,
             "Once for each step, and a cycle has two steps."),
    ]))

    four = [F(figure(walk_pose(k / 4))) for k in range(4)]
    L.append(lesson("walk.loop", "Make It Loop", "Walk in place, then across the screen.", [
        read("In place, then across",
             "Animate the walk in place, like on a treadmill, and make the last frame lead into the first. Then Gale's "
             "Loops tool can repeat it and slide it across the screen.", G(walk_frames(8), fps=8, bg=[ground()])),
        frames("Four-frame walk", "Draw a quick walk in 4 frames: passing, contact, passing, contact.", four,
               bg=[ground()], hint="Frames 1 and 3 look alike but with the legs swapped. So do frames 2 and 4.",
               checks=[chk_loop()], fps=4, coverage=0.65),
        tool("Walk it across", "Turn your walk into a loop and send it across a scene.", "loops", [
            "Select your walk frames and choose Save as Loop.",
            "Drop the loop into a new scene.",
            "Make it walk to the right and choose how many steps it takes.",
            "If the feet slide, change the stride until they stick to the ground.",
        ]),
        quiz("Why animate a walk in place first?", ["It's easier to make it loop, then move it across later",
                                                    "Characters never move", "It uses less ink"], 0,
             "In place, the loop is easy to check. Moving it across comes after."),
    ]))
    return course(course_id, TRACK, "Walk Cycle", "Poses, legs, arms and the bob", "figure.walk", ["ball"], L)


def run():
    L = []
    run8 = walk_frames(8, run=True)
    side = []
    for k in range(24):
        w = walk_pose((k / 12) % 1.0, hip_x=0.38, size=0.5)
        r_ = walk_pose((k / 8) % 1.0, hip_x=0.98, size=0.5, run=True)
        side.append(F(figure(w) + figure(r_), notes=[("walk", 0.38, 0.1), ("run", 0.98, 0.1)]))
    L.append(lesson("run.vs", "Run vs Walk", "Running is falling forward and catching yourself.", [
        read("Both feet off the ground",
             "In a run, there's a moment when both feet are off the ground. The body leans forward, the knees lift "
             "higher and the arms pump with the elbows bent.", G(run8, fps=10, bg=[ground()])),
        read("Side by side",
             "Compare them: the run leans forward, bounces more and takes fewer frames per cycle. That's why it "
             "looks faster.", G(side, fps=12, bg=[ground()])),
        quiz("What happens in a run that never happens in a walk?",
             ["Both feet leave the ground at once", "Both feet touch the ground at once", "The arms stay still"], 0,
             "That moment in the air is called the flight."),
    ]))

    poses = {k: walk_pose(k / 8, run=True) for k in range(8)}
    flight = min(poses, key=lambda k: max(poses[k]["near_leg"][-2][1], poses[k]["far_leg"][-2][1]))
    contact_k = max(range(8), key=lambda k: abs(poses[k]["near_leg"][2][0] - poses[k]["far_leg"][2][0]))
    labelled = []
    for k in range(8):
        nts = [("Flight", CX, 0.1)] if k == flight else ([("Contact", CX, 0.1)] if k == contact_k else None)
        labelled.append(F(figure(poses[k]), hold=3 if nts else 1, notes=nts))
    L.append(lesson("run.poses", "Run Poses", "Contact, push off and flight.", [
        read("The run poses",
             "A run has a contact (a foot lands), a down (the knee bends to catch you), a push off (the back leg "
             "drives you forward) and a flight (both feet in the air). Watch for the labels.", G(labelled, fps=8, bg=[ground()])),
        trace("Flight pose", "Trace the flight pose: both feet are off the ground.", figure(poses[flight]), bg=[ground()],
              hint="Front knee high, back leg stretched out behind."),
        trace("Contact pose", "Trace the contact pose: the front foot lands under the body.", figure(poses[contact_k]),
              bg=[ground()], hint="Lean the body forward."),
        quiz("Which way does a runner lean?", ["Forward", "Backward", "Straight up"], 0,
             "Leaning forward is how a runner keeps falling forward and catching themselves."),
    ]))

    legs6 = walk_frames(6, run=True, parts=LEGS)
    L.append(lesson("run.cycle", "Run It", "A fast, looping run cycle.", [
        read("Fast cycles",
             "At 12 frames per second, a run with 6 frames per cycle takes half a second. Fewer frames feel faster. "
             "Keep the knees high and the arms pumping.", G(walk_frames(6, run=True), fps=12, bg=[ground()])),
        frames("Run legs", "Draw the legs for a 6-frame run. Frame 6 leads into frame 1.", legs6, bg=[ground()],
               hint="Look for the frame where both feet are in the air.", checks=[chk_loop()], fps=10),
        quiz("To make a run look faster, you can...", ["Use fewer frames per cycle", "Use more frames per cycle",
                                                       "Make the character smaller"], 0,
             "Fewer frames per cycle means each step happens sooner."),
    ]))
    return course("run", TRACK, "Run Cycle", "Lean, flight and speed", "figure.run", ["walk"], L)



# ---------------------------------------------------------------- Effects

def flame(cx, base, h, w, t, n=40, sway=0.06):
    """A flame outline at loop time t (0..1). The sway travels up the flame so it flickers; loops exactly."""
    def spine(u):
        return cx + sway * u ** 1.4 * math.sin(TAU * (1.4 * u - t)) + 0.3 * sway * u * math.sin(TAU * (3 * u - 2 * t))

    def half(u):
        return w * math.sin(math.pi * u) ** 0.65 * (1 - u) ** 0.55 * (1 + 0.1 * math.sin(TAU * (2.5 * u - t)))
    left, right = [], []
    for i in range(n + 1):
        u = i / n
        y = base - h * u
        left.append((spine(u) - half(u), y))
        right.append((spine(u) + half(u), y))
    return left + list(reversed(right))[1:]


def effects():
    L = []
    fire = []
    for k in range(8):
        t = k / 8
        paths = [ink(flame(CX, 0.86, 0.6, 0.2, t), closed=True), ink(flame(CX, 0.86, 0.34, 0.1, t + 0.4, sway=0.03), closed=True)]
        # a small flame breaks off the top and rises away
        lt = (t * 2) % 1.0
        ly = 0.28 - 0.18 * lt
        s = 0.06 * (1 - lt)
        if s > 0.012:
            paths.append(ink(flame(CX + 0.04 * math.sin(TAU * t), ly, 2 * s, s * 0.5, t, n=12, sway=0.0), closed=True))
        fire.append(F(paths))
    L.append(lesson("effects.fire", "Fire", "Flames rise, flicker and break off.", [
        read("Flames rise and flicker",
             "Fire is always moving up. The bottom of a flame stays put, the middle waves side to side, and the tips "
             "stretch up, break off and disappear. Animate it as a loop of 6 to 8 frames, drawn straight ahead.",
             G(fire, fps=12)),
        trace("Draw a flame", "Trace the flame: one big outer shape and a smaller one inside.",
              [ink(flame(CX, 0.86, 0.6, 0.2, 0.0), closed=True), ink(flame(CX, 0.86, 0.34, 0.1, 0.4, sway=0.03), closed=True)],
              hint="Start at the bottom, sweep up one side to the tip, then down the other side.", checks=[chk_closed()]),
        frames("Flicker loop", "Draw the outer flame on 4 frames. Watch the wave travel up. Frame 4 leads into frame 1.",
               [F([ink(flame(CX, 0.86, 0.6, 0.2, k / 4), closed=True)]) for k in range(4)],
               hint="The bottom barely moves. The tip moves the most.", checks=[chk_loop()], fps=8),
        quiz("Which way do flames move?", ["Up, with tips that break off", "Down toward the ground", "They stay still"], 0,
             "Hot air rises, so flames reach upward and break off at the top."),
    ]))

    smoke = []
    puffs = 4
    for k in range(16):
        paths = [ink(rect(0.3, 0.6, 0.42, 0.86), closed=True)]
        for p in range(puffs):
            t = ((k / 16) + p / puffs) % 1.0
            e = ease_out(t)
            paths.append(ink(cloud_puff(0.36 + 0.5 * t, 0.55 - 0.42 * e, 0.035 + 0.1 * t, phase=t * 3), closed=True))
        smoke.append(F(paths))
    puff4 = [F([ink(cloud_puff(0.5 + 0.08 * k, 0.78 - 0.55 * ease_out(k / 3), 0.05 + 0.04 * k, phase=k), closed=True)])
             for k in range(4)]
    L.append(lesson("effects.smoke", "Smoke", "Puffs that grow, slow down and drift.", [
        read("Puffs that grow and slow",
             "Smoke starts small and fast near where it comes from. As it rises, each puff grows bigger, slows down, "
             "drifts with the wind and fades away.", G(smoke, fps=10)),
        frames("One puff", "Draw one puff rising. It grows each frame, and the gaps get smaller as it slows down.",
               puff4, hint="Big jump first, then smaller and smaller jumps.", checks=[chk_spacing("easeOut")], fps=6, loop=False),
        quiz("As a smoke puff rises, it should...", ["Grow bigger and slow down", "Shrink and speed up", "Stay the same"], 0,
             "Smoke spreads out and loses speed as it rises."),
    ]))

    water = 0.72
    splash = []
    drops = [(-0.05, -0.07), (0.05, -0.07), (-0.09, -0.05), (0.09, -0.05), (-0.03, -0.09), (0.03, -0.09)]
    g = 0.02
    for k in range(5):
        y = 0.1 + (water - 0.1) * (k / 4) ** 2
        splash.append(F([ink(ellipse(CX, y - 0.03, 0.025, 0.035, n=16), closed=True)]))
    for k in range(1, 12):
        paths = []
        crown_h = 0.2 * math.sin(math.pi * min(1.0, k / 8))
        if crown_h > 0.01:
            paths.append(ink(crown(CX, water, 0.14 + 0.01 * k, crown_h), closed=False))
        for vx, vy in drops:
            t = k
            x = CX + vx * t * 0.5
            yy = water - 0.12 + vy * t + 0.5 * g * t * t
            if yy < water:
                paths.append(ink(circle(x, yy, 0.012, n=10), closed=True))
        for ring in range(2):
            rr = 0.05 + 0.04 * (k - ring * 3)
            if rr > 0.05:
                paths.append(ink(ellipse(CX, water, rr * 1.4, rr * 0.3, n=40), closed=True))
        splash.append(F(paths))
    splash[-1]["hold"] = 8
    peak = []
    peak.append(ink(crown(CX, water, 0.18, 0.2), closed=False))
    for vx, vy in drops:
        t = 4
        peak.append(ink(circle(CX + vx * t * 0.5, water - 0.12 + vy * t + 0.5 * g * t * t, 0.014, n=10), closed=True))
    rip = [F([ink(ellipse(CX, 0.55, 0.12 + 0.13 * k, 0.04 + 0.04 * k, n=40), closed=True)]) for k in range(3)]
    L.append(lesson("effects.splash", "Water Splash", "Crowns, droplets and ripples.", [
        read("The splash",
             "When a drop hits water, it speeds up as it falls, then water jumps up in a crown, droplets fly out in "
             "arcs and fall back down (gravity again!), and rings of ripples spread out.",
             G(splash, fps=12, bg=[helper(line((0.05, water), (ASPECT - 0.05, water)))])),
        trace("The crown", "Trace the crown of water and the flying droplets.", peak,
              bg=[helper(line((0.05, water), (ASPECT - 0.05, water)))], hint="Draw the crown's spiky top first.", tolerance=0.04),
        frames("Ripples", "Draw a ripple ring growing outward on each frame.", rip,
               hint="Each ring is wider than the last, and flatter than a circle.", fps=6, loop=False),
        quiz("After droplets fly up, they...", ["Fall back down in curved arcs", "Keep flying up forever",
                                                 "Stop in the air"], 0, "Gravity bends their paths into arcs."),
    ]))

    sizes = [0.15, 0.6, 1.0, 1.25, 0.9, 0.55, 0.25, 0.08]
    sparkles = []
    spots = [(0.4, 0.4, 0), (0.95, 0.3, 3), (0.7, 0.7, 5)]
    for k in range(8):
        paths = []
        for x, y, off in spots:
            s = sizes[(k + off) % 8]
            paths.append(ink(sparkle(x, y, 0.14 * s), closed=True))
        sparkles.append(F(paths))
    L.append(lesson("effects.sparkle", "Sparkles", "Pop in, flash and shrink away.", [
        read("Twinkle",
             "Sparkles are quick: they pop in, flash at their biggest and shrink away. Give each sparkle different "
             "timing so they don't all twinkle at once.", G(sparkles, fps=12)),
        frames("Pop and shrink", "Draw one sparkle small, then at its biggest, then shrinking.",
               [F([ink(sparkle(CX, 0.5, 0.3 * s), closed=True)]) for s in (0.4, 1.0, 0.65)],
               hint="Four long points with skinny curves between them.", fps=6, loop=False),
        quiz("Why give each sparkle different timing?", ["So they don't all blink at once, which looks fake",
                                                         "To save frames"], 0, "Nature is a little random. Offset timing feels natural."),
    ]))
    return course("effects", TRACK, "Effects", "Fire, smoke, water and sparkles", "flame", ["ball"], L)


def crown(cx, water, half, h, spikes=5):
    """A splash crown: a cup of water rising from the surface with spiky tips."""
    pts = [(cx - half, water)]
    for i in range(spikes * 2 + 1):
        u = i / (spikes * 2)
        x = cx - half * 1.15 + 2 * half * 1.15 * u
        tip = i % 2 == 1
        y = water - h * (1.0 if tip else 0.62) * (1 - 0.3 * abs(2 * u - 1))
        pts.append((x, y))
    pts.append((cx + half, water))
    return catmull(pts, per=4)


def sparkle(cx, cy, r):
    pts = []
    for i in range(4):
        a = -math.pi / 2 + i * math.pi / 2
        tip = (cx + r * math.cos(a), cy + r * math.sin(a))
        pts.append(tip)
        mid = a + math.pi / 4
        pts.append((cx + r * 0.18 * math.cos(mid), cy + r * 0.18 * math.sin(mid)))
    return pts


# ---------------------------------------------------------------- Hair & Cloth

def ponytail_sim(head_xs, head_y, r, segs=6, seg_len=0.06):
    """A ponytail as a chain of segments. The hair's swing is a damped spring pulled back by the head's
    speed; each segment further down follows a little later, so the tail lags, overshoots when the head
    stops, then settles."""
    theta, vel = 0.0, 0.0
    swing = []
    prev_x = head_xs[0]
    for hx in head_xs:
        v = hx - prev_x
        prev_x = hx
        target = -min(math.radians(50), max(-math.radians(50), v * 9))
        vel = vel * 0.7 + (target - theta) * 0.3
        theta += vel
        swing.append(theta)

    def at(t):
        if t <= 0:
            return swing[0]
        i = int(t)
        if i >= len(swing) - 1:
            return swing[-1]
        f = t - i
        return swing[i] * (1 - f) + swing[i + 1] * f
    out = []
    for k, hx in enumerate(head_xs):
        root = (hx - r * 0.97, head_y + r * 0.2)
        pts = [root]
        for i in range(segs):
            a = at(k - 0.7 * i) * (1 + 0.12 * i)
            x, y = pts[-1]
            pts.append((x + seg_len * math.sin(a), y + seg_len * math.cos(a)))
        out.append(pts)
    return out
