"""Track "2D Animation": Bouncing Ball, Walk, Run, Acting, Effects, Hair & Cloth."""
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
    top = 0.15
    drop5 = [top + (BC - top) * (k / 4) ** 2 for k in range(5)]
    drop_frames = []
    for k in range(7):
        i = min(k, 4)
        paths = [ghost_ball(CX, drop5[j]) for j in range(i)]
        paths.append(ball(CX, drop5[i]))
        drop_frames.append(F(paths, hold=6 if k == 6 else 2))
    L.append(lesson("ball.drop", "The Drop", "Gravity makes falling things speed up.", [
        read("Gravity speeds things up",
             "When you drop a ball, it starts slow and falls faster and faster. That's gravity. So the gaps between "
             "your drawings get bigger each frame: small at the top, big at the bottom.", G(drop_frames, bg=[ground()])),
        frames("Drop it", "Draw the ball falling. Make each gap bigger than the one before.",
               [F([ball(CX, y)]) for y in drop5], bg=[ground()], hint="Tiny gap at the top, biggest gap at the bottom.",
               checks=[chk_spacing("easeIn")], fps=6, loop=False),
        quiz("When a ball falls, its drawings should be...",
             ["Close together at the top, far apart at the bottom", "Far apart at the top, close at the bottom",
              "Evenly spaced"], 0, "Gravity makes it faster as it falls, so the gaps grow."),
    ]))

    across = bounce_path(0.12, 0.2, 0.055, 0.011, 1.0, 20)
    across_frames = []
    for k, (x, y) in enumerate(across):
        across_frames.append(F([ball(x, y, r=0.06), accent(across[:k + 1])] if k else [ball(x, y, r=0.06)]))
    six = []
    for k in range(6):
        u = k / 6
        s = 2 * u - 1
        six.append(F([ball(CX, BC - 0.58 * (1 - s * s))]))
    L.append(lesson("ball.bounce", "The Bounce", "Up, down, and up again.", [
        read("Up, down, up",
             "A bounce is a fall and a rise. Going up, the ball slows down until it stops at the top for a moment. "
             "Coming down, it speeds up until it hits the ground. So the drawings bunch up at the top and spread "
             "out near the ground.", G([F([p]) for p in vertical_bounce(CX, squash=False)], bg=[ground()])),
        read("Moving forward",
             "If the ball also moves sideways, the sideways spacing stays even while the up-and-down spacing "
             "follows gravity. Together they make an arc, like the orange path.", G(across_frames, bg=[ground()], fps=12)),
        frames("One bounce", "Draw a whole bounce in place: ground, rising, top, falling. Frame 6 leads back to frame 1.",
               six, bg=[ground()], hint="The two drawings near the top are close together. Near the ground they're far apart.",
               checks=[chk_loop()], fps=8),
        quiz("Where does a bouncing ball move slowest?",
             ["At the top of the bounce", "Just before it hits the ground", "It's always the same speed"], 0,
             "At the top it stops going up and starts coming down, so it's slowest there."),
    ]))

    shapes = still([ball(0.3, 0.5, r=0.12), ball(CX, 0.5, r=0.12, stretch=1 / 0.62, angle=0.0),
                    ball(1.04, 0.5, r=0.12, stretch=1.45)],
                   notes=[("normal", 0.3, 0.75), ("squash", CX, 0.75), ("stretch", 1.04, 0.8)])
    rb = 0.1
    L.append(lesson("ball.squash", "Squash & Stretch", "Make the bounce feel soft.", [
        read("Squish on impact",
             "Now add squash and stretch. Just before and after it hits the ground, the ball is moving fastest, so "
             "it stretches along its path. On the frame it touches the ground, it squashes flat. At the top it's round.",
             G([F([p]) for p in vertical_bounce(CX)], bg=[ground()])),
        read("Keep the volume",
             "A squashed ball gets wider. A stretched ball gets thinner. It always keeps the same amount of ball, "
             "or it will look like it's growing and shrinking.", shapes),
        frames("Three key drawings",
               "Draw the ball stretched as it falls, squashed on the ground, then stretched as it shoots back up.",
               [F([ball(CX, 0.55, rb, stretch=1.35)]), F([ink_squash(CX, FLOOR, rb, 0.65)]),
                F([ball(CX, 0.4, rb, stretch=1.25)])],
               bg=[ground()], hint="Tall and thin, then short and wide, then tall and thin again.", fps=4),
        quiz("When is the ball stretched the most?",
             ["When it's moving fastest, near the ground", "At the very top", "When it's lying still"], 0,
             "Speed causes stretch, and the ball is fastest near the ground."),
    ]))

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
    return course("ball", TRACK, "Bouncing Ball", "Timing, spacing, squash and stretch", "circle.circle", ["basics"], L)


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


# ---------------------------------------------------------------- Acting & Lip Sync

def acting():
    L = []
    MX, MY, MS = CX, 0.5, 1.6
    cycle = [F(mouth(m, MX, MY, MS), hold=8, notes=[(MOUTH_WORDS[m], MX, 0.12)]) for m in MOUTHS]
    L.append(lesson("acting.mouths", "Mouth Shapes", "A few shapes cover every sound.", [
        read("A few shapes say it all",
             "You don't need a new mouth for every letter. About eight shapes cover almost every sound: A (open), "
             "E (wide), O (round), U (small and round), M B P (lips pressed), F V (top teeth on the lip), "
             "L (tongue up) and a resting mouth.", G(cycle)),
        trace("O", "Trace the O shape: round lips, like saying \"oh\".", mouth("O", MX, MY, MS), hint="Two ovals, one inside the other."),
        trace("E", "Trace the E shape: wide, like a big \"eee\" smile.", mouth("E", MX, MY, MS), hint="A wide oval with a line of teeth."),
        trace("M B P", "Trace the M B P shape: lips pressed together.", mouth("MBP", MX, MY, MS),
              hint="The top lip, the bottom lip and the line where they meet."),
        quiz("Which mouth shape do you use for the M in \"mom\"?", ["Lips pressed together", "Wide open", "Round O"], 0,
             "M, B and P all start with the lips pressed shut."),
    ]))

    hello = [("E", 2), ("L", 2), ("O", 5), ("rest", 8)]
    say = [F(face(mouth_shape=m), hold=h, notes=[({"E": "he", "L": "l", "O": "lo", "rest": ""}[m] or "...", CX, 0.05)])
           for m, h in hello]
    L.append(lesson("acting.word", "Say a Word", "Lip sync \"hello\".", [
        read("Say hello",
             "To lip sync, say the word slowly and listen for the main sounds. \"Hello\" is roughly E, L, O. Hold the "
             "vowels (like the O at the end) a little longer, and skip the tiny sounds.", G(say, fps=12)),
        frames("Draw hello", "Draw the four mouths for \"hello\": E, L, O, then rest.",
               [F(mouth(m, MX, MY, MS)) for m, _ in hello], hint="Use the faint guide for each shape.", fps=4,
               loop=False),
        quiz("Do you need a new mouth shape for every letter?", ["No, just the main sounds", "Yes, every single letter"], 0,
             "Animating every letter looks fluttery. Pick the sounds you can hear."),
        quiz("Which sounds usually get held the longest?", ["Vowels like A, E and O", "Sounds like T and K"], 0,
             "Vowels are the long, open sounds in a word."),
    ]))

    EX, EY, ES = CX, 0.5, 0.32
    seq = [(1.0, 10), (0.5, 1), (0.0, 2), (0.5, 1), (1.0, 14)]
    blink = [F(eye(EX, EY, ES, o), hold=h) for o, h in seq]
    L.append(lesson("acting.blink", "Blinks", "Quick blinks make characters feel alive.", [
        read("A quick blink",
             "A blink is fast: open, half closed, closed, half open, open. The closed eye only stays for a frame or "
             "two, and the top lid does most of the moving. A slow blink can show a character is tired or thinking.",
             G(blink)),
        frames("Draw a blink", "Draw the eye open, half closed, then closed.",
               [F(eye(EX, EY, ES, o)) for o in (1.0, 0.5, 0.0)], hint="The top lid slides down each frame.", fps=4,
               loop=False),
        quiz("Which eyelid moves the most in a blink?", ["The top lid", "The bottom lid"], 0,
             "The top lid comes down to meet the bottom one."),
    ]))

    def pose_on(curve_pts, base):
        """A stick pose built along a line of action (hips at the bottom, head at the top)."""
        hip = curve_pts[0]
        neck = curve_pts[-1]
        spine = curve_pts
        d = (neck[0] - curve_pts[-2][0], neck[1] - curve_pts[-2][1])
        Ld = math.hypot(*d) or 1
        head = (neck[0] + d[0] / Ld * 0.07, neck[1] + d[1] / Ld * 0.07)
        sh = curve_pts[int(len(curve_pts) * 0.85)]
        arms = [[sh, (sh[0] - 0.14, sh[1] - 0.1), (sh[0] - 0.22, sh[1] - 0.22)],
                [sh, (sh[0] + 0.12, sh[1] + 0.06), (sh[0] + 0.24, sh[1])]]
        legs = [[hip, (hip[0] - 0.08, hip[1] + 0.15), (hip[0] - 0.14, base)],
                [hip, (hip[0] + 0.1, hip[1] + 0.14), (hip[0] + 0.16, base)]]
        return [ink(spine), ink(circle(head[0], head[1], 0.07, n=24), closed=True)] + [ink(a) for a in arms + legs]
    straight_c = [(CX, 0.58 - 0.36 * t) for t in (i / 10 for i in range(11))]
    c_curve = [(CX - 0.12 * math.sin(math.pi * t), 0.58 - 0.36 * t) for t in (i / 10 for i in range(11))]
    s_curve = [(CX + 0.07 * math.sin(TAU * t), 0.58 - 0.36 * t) for t in (i / 10 for i in range(11))]
    loa = []
    for name, c in (("stiff", straight_c), ("C curve", c_curve), ("S curve", s_curve)):
        loa.append(F(pose_on(c, 0.86) + [accent(move(c, 0.0, 0.0), w=0.01)], hold=14, notes=[(name, CX, 0.08)]))
    big_c = [(CX - 0.25 * math.sin(math.pi * t), 0.88 - 0.76 * t) for t in (i / 30 for i in range(31))]
    L.append(lesson("acting.pose", "Line of Action", "Strong poses flow along one line.", [
        read("One strong line",
             "A strong pose follows one clear line through the whole body, called the line of action. A C-curve or an "
             "S-curve feels full of energy. A stiff straight line feels flat. The orange line is the line of action.",
             G(loa)),
        trace("Draw the line of action", "Trace a big, confident C-curve. This is where a pose starts.", [ink(big_c)],
              hint="One smooth sweep, from bottom to top.", checks=[chk_smooth()]),
        trace("Build a pose on it", "Trace a pose that follows the C-curve: the back bends along the line.",
              pose_on(c_curve, 0.86), hint="Start with the curved back, then the head, then the arms and legs."),
        quiz("Which line of action has the most energy?", ["A curvy C or S line", "A stiff straight line"], 0,
             "Curves feel alive; straight lines feel stiff."),
    ]))
    return course("acting", TRACK, "Acting & Lip Sync", "Mouth shapes, blinks and strong poses", "face.smiling",
                  ["principles"], L)


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


def hair():
    L = []
    n = 30
    xs = []
    for k in range(n):
        if k < 10:
            xs.append(0.35 + 0.55 * ease_in_out(k / 9))
        else:
            xs.append(0.9)
    hy, hr = 0.35, 0.12
    tails = ponytail_sim(xs, hy, hr)
    follow = [F([ink(circle(x, hy, hr, n=36), closed=True), ink(catmull(t, per=3))]) for x, t in zip(xs, tails)]
    after = list(range(10, n))
    over = max(after, key=lambda k: tails[k][-1][0] - xs[k])
    back = min(range(over, n), key=lambda k: tails[k][-1][0] - xs[k])
    picks = [over, back, n - 1]
    L.append(lesson("hair.follow", "Hair Follows", "Hair drags behind, overshoots, then settles.", [
        read("Hair drags behind",
             "Hair is attached at the roots, but the rest is loose. When the head moves, the hair lags behind. When "
             "the head stops, the hair keeps going, swings past, then settles. The tips are always last.", G(follow, fps=12)),
        frames("Stop and settle", "The head just stopped. Draw the ponytail swinging past, swinging back, then hanging still.",
               [F([ink(circle(xs[k], hy, hr, n=36), closed=True), ink(catmull(tails[k], per=3))]) for k in picks],
               hint="The tip of the ponytail moves the most.", fps=4, loop=False),
        quiz("When a character stops suddenly, their ponytail...", ["Keeps swinging, then settles", "Stops instantly",
                                                                    "Points straight up"], 0,
             "Loose things carry on moving: that's follow through."),
    ]))

    pole_x, top_y, bot_y, flag_w = 0.3, 0.2, 0.5, 0.75

    def flag(t, n_=24):
        def off(u):
            return 0.06 * u * math.sin(TAU * (1.2 * u - t))
        top = [(pole_x + flag_w * u, top_y + off(u) + 0.02 * u) for u in (i / n_ for i in range(n_ + 1))]
        bottom = [(pole_x + flag_w * u, bot_y + off(u) - 0.01 * u) for u in (i / n_ for i in range(n_ + 1))]
        return top + list(reversed(bottom))
    pole = [helper(line((pole_x, 0.12), (pole_x, 0.92)), w=0.012)]
    L.append(lesson("hair.flag", "Waving Flag", "Waves travel along the cloth.", [
        read("Waves travel",
             "On a flag, the cloth is held still at the pole. The wind sends waves along the cloth from the pole to the "
             "free end, and the free end flaps the most.", G([F([ink(flag(k / 12), closed=True)]) for k in range(12)], bg=pole)),
        frames("Flag loop", "Draw the flag on 4 frames. Watch the wave move away from the pole. Frame 4 leads into frame 1.",
               [F([ink(flag(k / 4), closed=True)]) for k in range(4)], bg=pole,
               hint="The edge at the pole never moves.", checks=[chk_loop()], fps=6),
        quiz("Which way do the waves travel on a flag?", ["From the pole to the free end", "From the free end to the pole"],
             0, "The pole holds one end, so the waves start there and run outward."),
    ]))

    def caped(t):
        pose = walk_pose(t, run=True, hip_x=0.8)
        neck = pose["torso"][1]
        hip = pose["torso"][0]
        sh = lerp2(hip, neck, 0.95)
        length_ = 0.42
        top_edge = []
        bot_edge = []
        for i in range(13):
            u = i / 12
            wv = 0.035 * u * math.sin(TAU * (1.5 * u - 2 * t))
            top_edge.append((sh[0] - length_ * u, sh[1] + 0.02 + 0.1 * u * u + wv))
            bot_edge.append((sh[0] - 0.02 - length_ * u * 0.95, sh[1] + 0.18 + 0.12 * u + wv))
        cape = top_edge + list(reversed(bot_edge))
        return figure(pose) + [ink(cape, closed=True)], cape
    cape_frames = [F(caped(k / 8)[0]) for k in range(8)]
    L.append(lesson("hair.cape", "Capes & Scarves", "Cloth that drags and ripples.", [
        read("Capes and scarves",
             "A cape or scarf works like hair and a flag together: attached at one end, it drags behind when the "
             "character moves, and waves ripple from the attached end to the tip. The faster the character, the "
             "flatter the cape flies.", G(cape_frames, fps=10, bg=[ground()])),
        trace("Draw the cape", "Trace the runner and the cape flying behind.", caped(0.0)[0], bg=[ground()],
              hint="Draw the runner first, then the cape from the shoulders backward."),
        tool("Sway a scarf", "Hair Sway works on cloth too.", "hairSway", [
            "Draw a scarf or cape on its own layer.",
            "Use Hair Sway on it, just like hair: circle it and draw the root line where it's attached.",
            "Turn up the wind so it blows back, and add gusts for flapping.",
        ]),
        quiz("What makes a cape fly flatter behind a character?", ["Moving faster", "Moving slower", "Standing still"], 0,
             "More speed means more wind pushing the cape back."),
    ]))
    return course("hair", TRACK, "Hair & Cloth", "Follow through, flags and capes", "wind", ["principles"], L)



