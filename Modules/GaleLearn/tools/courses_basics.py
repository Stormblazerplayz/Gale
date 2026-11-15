"""Track "2D Animation": Drawing Basics and Gale's Tools."""
import math
import random

from learn_geo import (ASPECT, GROUND, TAU, arc, catmull, circle, dist, ease_in_out, ellipse, lerp, lerp2, line,
                       move, partial, polygon, pulled_string, rect, scale, sine_wave, spiral)
from learn_dsl import (F, G, accent, chk_closed, chk_loop, chk_smooth, chk_spacing, chk_straight, course, frames,
                       helper, ink, lesson, quiz, read, still, tool, trace)
from content_kit import CX, ball, cloud_puff, dot, draw_on, ghost_ball, ground, heart, mountains, tree

TRACK = "animation"


# ---------------------------------------------------------------- Drawing Basics

def basics():
    lessons = []

    # 1. Straight lines
    a, b = (0.22, 0.5), (1.11, 0.5)
    ends = [dot(*a), dot(*b)]
    ghost = []
    for k in range(13):
        t = 0.5 - 0.5 * math.cos(TAU * k / 6.5)
        p = lerp2(a, b, t)
        ghost.append(F(ends + [helper(line(a, b), w=0.004), accent(circle(p[0], p[1] + 0.03, 0.012, n=12), closed=True)]))
    ghost += draw_on([line(a, b, n=12)], steps=6, hold_end=12, extras=ends)
    lessons.append(lesson("basics.lines", "Straight Lines", "Pull clean, confident lines in one move.", [
        read("Pull, don't push",
             "Wobbly lines happen when we draw slowly using only our fingers. Instead, move your whole arm "
             "from the shoulder and pull the line in one quick, smooth move. Watch: the line starts gently, "
             "speeds up, and lands right on the end dot.",
             G(draw_on([line(a, b, n=12)], steps=10, hold_end=14, extras=ends))),
        read("Ghost it first",
             "Before you touch the screen, hover your pencil over the path and practice the move two or three "
             "times. This is called ghosting. Once your arm knows the way, put the pencil down and draw it in one go.",
             G(ghost)),
        trace("Across", "Start on the left dot and pull straight across to the right dot.",
              [ink(line((0.2, 0.5), (1.13, 0.5), n=8))] + [dot(0.2, 0.5), dot(1.13, 0.5)],
              hint="Ghost the move first, then draw it in one quick pull without stopping.",
              checks=[chk_straight()]),
        trace("Down", "Now from the top dot straight down to the bottom dot.",
              [ink(line((CX, 0.12), (CX, 0.88), n=8)), dot(CX, 0.12), dot(CX, 0.88)],
              hint="Keep your wrist still and move your whole arm down.", checks=[chk_straight()]),
        trace("Slant", "A slanted line from the bottom left dot up to the top right dot.",
              [ink(line((0.3, 0.82), (1.03, 0.18), n=8)), dot(0.3, 0.82), dot(1.03, 0.18)],
              hint="Turn the iPad if a different angle feels easier. Artists do it all the time!",
              checks=[chk_straight()]),
        quiz("What helps you draw a straighter line?",
             ["Drawing very slowly with your fingertips", "One quick, steady pull with your whole arm",
              "Lots of tiny short strokes"], 1,
             "A quick pull from the shoulder keeps the line steady from start to end."),
    ]))

    # 2. Curves and circles
    circ = circle(CX, 0.5, 0.3, n=48)
    lessons.append(lesson("basics.curves", "Curves & Circles", "Smooth curves and circles that close up.", [
        read("One smooth turn",
             "A circle is one line that keeps curving by the same amount all the way round. Start at the top, "
             "keep your speed steady, and finish exactly where you began.",
             G(draw_on([circ + [circ[0]]], steps=12, hold_end=12, extras=[dot(CX, 0.2)]))),
        trace("C-curve", "Trace the C. Keep the speed steady so the curve stays smooth.",
              [ink(arc(CX + 0.05, 0.5, 0.3, 0.3, math.pi / 3, 5 * math.pi / 3, n=40))],
              hint="Move your whole arm and don't stop halfway round.", checks=[chk_smooth()]),
        trace("Circle", "Start at the dot on top, go all the way round, and end where you started.",
              [ink(circ, closed=True), dot(CX, 0.2)],
              hint="Ghost the circle in the air a couple of times first, then draw.",
              checks=[chk_closed(), chk_smooth()]),
        trace("Oval", "An oval is a stretched circle. Same trick: one smooth loop.",
              [ink(ellipse(CX, 0.5, 0.42, 0.22, n=48), closed=True)],
              hint="Go a little faster along the long sides.", checks=[chk_closed(), chk_smooth()]),
        quiz("Your circle has a gap where the ends don't meet. What's the best fix?",
             ["Leave the gap, nobody will notice", "Redraw it in one smooth loop and end where you started",
              "Draw lots of short lines to fill the gap"], 1,
             "One smooth loop that ends where it began gives a clean, closed circle."),
    ]))

    # 3. Waves and S-curves
    wave_frames = [F([ink(sine_wave(0.12, ASPECT - 0.12, 0.5, 0.13, 2.0, phase=-TAU * k / 12, n=70))]) for k in range(12)]
    s_curve = [(CX - 0.2 * math.sin(TAU * t), 0.12 + 0.76 * t) for t in (i / 60 for i in range(61))]
    lessons.append(lesson("basics.waves", "Waves & S-Curves", "Lines with rhythm, like water and tails.", [
        read("Lines with rhythm",
             "Lots of things move in waves: water, flags, hair, a cat's tail. An S-curve bends one way, then the "
             "other. Keep your hand moving at a steady speed and let the line flow.",
             G(wave_frames)),
        trace("S-curve", "Trace the S from top to bottom in one move.", [ink(s_curve)],
              hint="Let your wrist swing gently left, then right, as your arm moves down.", checks=[chk_smooth()]),
        trace("Waves", "Ride the waves from left to right.", [ink(sine_wave(0.15, ASPECT - 0.15, 0.5, 0.13, 2.0, n=80))],
              hint="Keep the tops and the dips the same height.", checks=[chk_smooth()]),
        trace("Spiral", "Start in the middle and spiral outward.", [ink(spiral(CX, 0.5, 0.03, 0.37, 2.5, n=200))],
              hint="Turn the page with your other hand if it helps, and keep the gaps even.", checks=[chk_smooth()]),
        quiz("Which of these moves like a wave?", ["A brick falling", "A flag in the wind", "A parked car"], 1,
             "Wind sends ripples along a flag, just like an S-curve repeating."),
    ]))

    # 4. Shapes from lines
    sq = rect(0.42, 0.25, 0.92, 0.75)
    sides = [line(sq[i], sq[(i + 1) % 4], n=6) for i in range(4)]
    tri = polygon(CX, 0.56, 0.33, 3)
    hx0, hx1, hy0, hy1 = 0.45, 0.89, 0.45, 0.85
    house = [ink(rect(hx0, hy0, hx1, hy1), closed=True),
             ink([(hx0, hy0), (CX, 0.16), (hx1, hy0)] + [(hx0, hy0)], closed=False),
             ink(rect(0.62, 0.62, 0.72, 0.85), closed=True)]
    lessons.append(lesson("basics.shapes", "Shapes With Corners", "Squares, triangles and closed shapes.", [
        read("Corners and sides",
             "Shapes with corners, like squares and triangles, are just straight lines that meet. Draw each side "
             "as its own quick line, and make sure the corners touch so the shape is closed with no gaps.",
             G(draw_on(sides, steps=12, hold_end=12))),
        trace("Square", "Trace the square. You can draw it as four lines or one.", [ink(sq, closed=True)],
              hint="Stop exactly on each corner before you start the next side.", checks=[chk_closed()]),
        trace("Triangle", "Three sides, three corners. Close it up!", [ink(tri, closed=True)],
              hint="Start at the top point and go round.", checks=[chk_closed()]),
        trace("House", "Shapes can join up to make things. Trace the house, its roof and its door.", house,
              hint="Draw the big square first, then the roof on top, then the door.", checks=[chk_closed()]),
        quiz("Why do closed shapes matter when you color with the paint bucket?",
             ["The color leaks out through any gap", "They make the brush thicker", "They don't matter at all"], 0,
             "The paint bucket fills inside the lines. If there's a gap, the color spills out across the page."),
    ]))

    # 5. Thick and thin
    near = ink(circle(0.42, 0.58, 0.2, n=40), w=0.032, closed=True)
    far = ink(circle(1.0, 0.36, 0.08, n=24), w=0.007, closed=True)
    path = arc(CX, 0.9, 0.5, 0.55, -0.85 * math.pi, -0.15 * math.pi, n=40)
    left, right = [], []
    for i in range(len(path)):
        t = i / (len(path) - 1)
        a = path[max(0, i - 1)]
        b2 = path[min(len(path) - 1, i + 1)]
        nx, ny = -(b2[1] - a[1]), b2[0] - a[0]
        L = math.hypot(nx, ny) or 1
        wdt = 0.045 * math.sin(math.pi * t) + 0.002
        left.append((path[i][0] + nx / L * wdt, path[i][1] + ny / L * wdt))
        right.append((path[i][0] - nx / L * wdt, path[i][1] - ny / L * wdt))
    taper_shape = left + list(reversed(right))
    leaf_l = [(CX + 0.36 * u, 0.5 - 0.2 * (1 - u * u)) for u in (i / 15 - 1 for i in range(31))]
    leaf_r = [(CX + 0.36 * u, 0.5 + 0.2 * (1 - u * u)) for u in (i / 15 - 1 for i in range(31))]
    lessons.append(lesson("basics.weight", "Thick & Thin Lines", "Line weight makes drawings feel deep.", [
        read("Line weight",
             "Line weight means how thick a line is. Thick lines feel close, heavy or in shadow. Thin lines feel "
             "far away or light. With Apple Pencil, press harder for a thicker line.",
             still([near, far, ground(0.8)], notes=[("Close", 0.42, 0.9), ("Far", 1.0, 0.52)])),
        read("Taper your lines",
             "A line that starts thin, gets thicker in the middle and ends thin looks alive. Start gently, press "
             "in the middle, then lift off at the end. Here's the shape a tapered line makes.",
             G([F([ink(taper_shape, w=0.006, closed=True)], hold=1)], loop=False)),
        trace("Leaf", "Trace the leaf: two curves that meet at the tips, then the line down the middle.",
              [ink(leaf_l), ink(leaf_r), ink(line(lerp2(leaf_l[0], leaf_l[-1], 0.04), lerp2(leaf_l[0], leaf_l[-1], 0.96), n=6))],
              hint="Try pressing lightly at the tips and harder in the middle.", checks=[chk_smooth()]),
        tool("Feel the pressure", "Try line weight in your own drawing.", "brush", [
            "Open a project and pick the Ink Brush.",
            "Draw a line pressing very lightly.",
            "Draw another line pressing hard.",
            "Now draw one line that starts light, presses in the middle and ends light.",
        ]),
        quiz("You want a tree to look far away. What lines should you use?",
             ["Thick, dark lines", "Thin, light lines", "Dotted lines"], 1,
             "Thin, light lines make things feel further away."),
    ]))

    # 6. Build with simple shapes
    hx, hy, hr = 0.5, 0.36, 0.13
    ear_l = [(hx - 0.12, hy - 0.06), (hx - 0.1, hy - 0.22), (hx - 0.02, hy - 0.12)]
    ear_r = [(hx + 0.02, hy - 0.12), (hx + 0.1, hy - 0.22), (hx + 0.12, hy - 0.06)]
    body = ellipse(0.75, 0.6, 0.24, 0.15, n=40)
    tail = catmull([(0.98, 0.58), (1.1, 0.5), (1.12, 0.36), (1.06, 0.26)], per=10)
    legs = [line((x, 0.7), (x, 0.84), n=3) for x in (0.6, 0.68, 0.84, 0.92)]
    head = circle(hx, hy, hr, n=36)
    eyes = [circle(hx - 0.045, hy - 0.01, 0.016, n=10), circle(hx + 0.045, hy - 0.01, 0.016, n=10)]
    nose = [(hx - 0.015, hy + 0.04), (hx + 0.015, hy + 0.04), (hx, hy + 0.06)]
    parts = [("body", [body], True), ("head", [head], True), ("ears", [ear_l + [ear_l[0]], ear_r + [ear_r[0]]], False),
             ("tail", [tail], False), ("legs", legs, False), ("face", eyes + [nose + [nose[0]]], False)]
    build = []
    shown = []
    for name, shapes, closed in parts:
        for s in shapes:
            shown.append(ink(s, closed=closed))
        build.append(F(list(shown), hold=6, notes=[("+ " + name, 0.2, 0.9)]))
    build[-1]["hold"] = 16
    lessons.append(lesson("basics.build", "Build With Shapes", "Turn circles, ovals and triangles into a cat.", [
        read("Everything is shapes",
             "Artists don't draw a cat all at once. They start with simple shapes: a circle for the head, an oval "
             "for the body, triangles for the ears. Then they add details on top. Watch the cat get built.",
             G(build)),
        trace("The head", "Start with the head: a circle and two triangle ears.",
              [ink(head, closed=True), ink(ear_l + [ear_l[0]]), ink(ear_r + [ear_r[0]])],
              hint="Draw the circle first, then the ears.", checks=[chk_closed(0.07)]),
        trace("The body", "Now the oval body and a curvy tail.", [ink(body, closed=True), ink(tail)],
              hint="Keep the oval smooth, then flick the tail up.", checks=[chk_smooth()]),
        trace("The whole cat", "Put it all together: head, ears, body, tail and legs.",
              [ink(head, closed=True), ink(ear_l + [ear_l[0]]), ink(ear_r + [ear_r[0]]), ink(body, closed=True), ink(tail)]
              + [ink(l) for l in legs],
              hint="Big shapes first, small shapes last.", coverage=0.65),
        quiz("What should you draw first?",
             ["The whiskers and eyes", "Big simple shapes like circles and ovals", "The fur, one hair at a time"], 1,
             "Big shapes first set the size and pose. Details go on top at the end."),
    ]))

    return course("basics", TRACK, "Drawing Basics", "Smooth, confident lines and shapes", "scribble.variable", [], lessons)


# ---------------------------------------------------------------- Gale's Tools

def tools():
    lessons = []

    # 1. Stabilizer
    rng = random.Random(3)
    base = sine_wave(0.15, ASPECT - 0.15, 0.5, 0.15, 1.5, n=120)
    shaky = [(x + rng.uniform(-0.012, 0.012), y + rng.uniform(-0.018, 0.018)) for x, y in base]
    smooth = catmull(pulled_string(shaky, 0.03)[::2], per=4)
    stab = []
    for i in range(13):
        t = i / 12
        stab.append(F([accent(partial(shaky, max(0.01, t)), w=0.006), ink(partial(smooth, max(0.01, t)))],
                      hold=14 if i == 12 else 1, notes=[("Shaky hand", 0.18, 0.2), ("What Gale draws", 0.95, 0.85)]))
    lessons.append(lesson("tools.stabilizer", "The Stabilizer", "Smooth lines, even with shaky hands.", [
        read("Smooth lines for shaky hands",
             "Gale's stabilizer works like a string. Your brush sits at the end of an invisible string and only "
             "moves when your pencil pulls the string tight. Little shakes never pull it, so they disappear. "
             "The orange line is a shaky hand. The dark line is what Gale draws.", G(stab)),
        tool("Try the stabilizer", "Draw the same wavy line with different stabilizer amounts and compare.", "stabilizer", [
            "Set the stabilizer to 0 and draw a slow wavy line.",
            "Turn it up to the middle and draw the same line.",
            "Turn it all the way up. The line trails a little behind your pencil, but it's very smooth.",
        ]),
        trace("Big spiral", "Trace the spiral. Turn the stabilizer up if your line gets wobbly.",
              [ink(spiral(CX, 0.5, 0.04, 0.38, 2.25, n=200))],
              hint="Draw a bit slower than usual and let the stabilizer smooth it out.", checks=[chk_smooth()]),
        quiz("When is a low stabilizer better?",
             ["Tiny details and quick, sharp marks", "Long smooth curves", "Big circles"], 0,
             "A strong stabilizer trails behind your pencil and rounds off sharp corners, so turn it down for small, "
             "quick details."),
    ]))

    # 2. Layers
    def sheet(dx, dy, content, label):
        x0, y0 = 0.25 + dx, 0.3 + dy
        outline = [(x0, y0), (x0 + 0.62, y0), (x0 + 0.72, y0 + 0.28), (x0 + 0.1, y0 + 0.28)]
        return [helper(outline, closed=True)] + [ink(move(c, dx, dy)) for c in content], (label, x0 + 0.78, y0 + 0.16)
    hills = [mountains(0.33, 0.95, 0.56, 0.16, n=40)]
    tree_c = [cloud_puff(0.6, 0.42, 0.06), line((0.6, 0.48), (0.6, 0.55))]
    kid = [circle(0.75, 0.39, 0.03, n=14), line((0.75, 0.42), (0.75, 0.5)), [(0.71, 0.56), (0.75, 0.5), (0.79, 0.56)]]
    layer_frames = []
    for k in range(16):
        spread = 0.5 - 0.5 * math.cos(TAU * k / 16)
        paths, notes = [], []
        for i, (content, label) in enumerate(((hills, "Back"), (tree_c, "Middle"), (kid, "Front"))):
            ps, note = sheet(0, (i - 1) * 0.2 * spread, content, label)
            paths += ps
            if spread > 0.6:
                notes.append(note)
        layer_frames.append(F(paths, notes=notes))
    rng = random.Random(5)
    sketch = []
    for k in range(4):
        jit = [(x + rng.uniform(-0.02, 0.02), y + rng.uniform(-0.02, 0.02))
               for x, y in circle(CX + rng.uniform(-0.02, 0.02), 0.5 + rng.uniform(-0.02, 0.02), 0.25, n=20)]
        sketch.append(helper(jit + [jit[0]], w=0.008))
    clean = circle(CX, 0.5, 0.25, n=48)
    clean_frames = [F(sketch, hold=10, notes=[("Messy sketch", CX, 0.88)])]
    for f in draw_on([clean + [clean[0]]], steps=8, hold_end=8, extras=sketch):
        clean_frames.append(f)
    clean_frames.append(F([ink(clean, closed=True)], hold=14, notes=[("Sketch hidden", CX, 0.88)]))
    lessons.append(lesson("tools.layers", "Layers", "Stack drawings like clear sheets.", [
        read("Clear sheets",
             "Layers are like clear plastic sheets stacked on top of each other. Draw the background on one, a "
             "tree on another and your character on the top one. Then you can change one without messing up "
             "the others.", G(layer_frames)),
        read("Sketch, then clean up",
             "A great trick: do a messy sketch on one layer and turn its opacity down so it's faint. Make a new "
             "layer on top and draw clean lines over it. When you're done, hide the sketch layer.", G(clean_frames)),
        tool("Make a sketch layer", "Set up a sketch layer and an ink layer.", "layers", [
            "Open the Layers panel and add a new layer.",
            "Name the bottom layer Sketch and do a quick, loose drawing.",
            "Turn the Sketch layer's opacity down to about 30%.",
            "Add a layer on top called Ink and trace clean lines.",
            "Hide the Sketch layer to see your clean drawing.",
        ]),
        quiz("Why put a sketch on its own layer?",
             ["So you can fade it and hide it later", "It makes the app faster", "Layers change the brush color"], 0,
             "On its own layer, the sketch can be faded while you ink, then hidden when you're done."),
    ]))

    # 3. Onion skin
    xs = [0.3, 0.55, 0.8, 1.05]
    onion = []
    for k in range(len(xs) + 2):
        i = min(k, len(xs) - 1)
        paths = [ghost_ball(xs[j], 0.5) for j in range(max(0, i - 2), i)]
        paths.append(ball(xs[i], 0.5))
        onion.append(F(paths, hold=4))
    lessons.append(lesson("tools.onion", "Onion Skin", "See the frames before and after.", [
        read("See through time",
             "Onion skin shows faint copies of the frames before and after the one you're drawing, like looking "
             "through thin onion paper. Frames before are blue and frames after are orange. In Gale they're "
             "frosted, a little blurry and milky, so they guide you without getting in the way.", G(onion, fps=8)),
        frames("Slide the ball",
               "Draw the ball on each frame. Use the frosted ghost of your last frame to keep the gaps the same.",
               [F([ball(x, 0.5)]) for x in xs], hint="Each ball should be the same distance from the last one.",
               checks=[chk_spacing("even")], fps=6),
        tool("Set up onion skin", "Find the onion skin settings in your own project.", "onionSkin", [
            "Turn on Onion Skin in the timeline.",
            "Show 2 frames before and 1 frame after.",
            "Switch frosted on and off. Which is easier to draw over?",
        ]),
        quiz("In onion skin, what does a blue ghost show?",
             ["A frame before this one", "A frame after this one", "A deleted frame"], 0,
             "Blue ghosts are frames that come before. Orange ghosts come after."),
    ]))

    # 4. Loops
    beat = [1.0, 1.06, 1.16, 1.22, 1.16, 1.06]
    scales4 = [1.0, 1.1, 1.2, 1.1]
    lessons.append(lesson("tools.loops", "Loops", "Animations that repeat forever.", [
        read("Animations that repeat",
             "A loop is an animation whose last frame leads right back into the first, so it can play forever: "
             "a beating heart, a spinning wheel, a walk cycle. Make it once and Gale can repeat it as long as you like.",
             G([F([ink(heart(CX, 0.5, 0.25 * s), closed=True)]) for s in beat], fps=10)),
        frames("Beating heart",
               "Draw the heart growing and shrinking. Frame 4 should lead back into frame 1.",
               [F([ink(heart(CX, 0.5, 0.25 * s), closed=True)]) for s in scales4],
               hint="Small, bigger, biggest, a bit smaller, and then it's back to small.",
               checks=[chk_loop()], fps=6),
        tool("Save a loop", "Turn your animation into a loop you can reuse.", "loops", [
            "Animate something that repeats, like your beating heart.",
            "Select its frames in the timeline and choose Save as Loop.",
            "Open a new scene and drop the loop in from the Loops shelf.",
            "Set how many times it plays.",
        ]),
        quiz("What makes a loop play smoothly?",
             ["The last frame leads into the first frame", "It has exactly 100 frames", "Every frame is the same"], 0,
             "When the last frame flows into the first, you can't see where the loop starts."),
    ]))

    # 5. Stash
    spots = [(0.3, 0.78), (0.62, 0.72), (0.95, 0.8), (0.45, 0.6), (1.12, 0.66)]
    st_frames = []
    for k in range(len(spots)):
        paths = []
        for (x, y) in spots[:k + 1]:
            paths += tree(x, y, h=0.3, w=0.15)
        st_frames.append(F(paths, hold=8))
    st_frames[-1]["hold"] = 16
    lessons.append(lesson("tools.stash", "The Stash", "Save drawings and reuse them anywhere.", [
        read("Keep it, reuse it",
             "The stash is a shelf for drawings you want to use again: a tree, a cloud, a prop or a character's "
             "head. Gale spots the separate things in your drawing by itself, so you can save each one with a tap "
             "and drag it into any frame.", G(st_frames, bg=[ground(0.82)])),
        trace("Draw a tree to stash", "Trace the tree. Next you'll save it in your own project.",
              tree(CX, 0.86, h=0.62, w=0.38), hint="Draw the bumpy top as one loop, then the trunk lines."),
        tool("Use the stash", "Fill a scene from your stash.", "stash", [
            "Draw a tree, a cloud and a rock in one frame.",
            "Open the Stash. Gale finds each separate thing for you.",
            "Save the tree, then drag it into another frame.",
            "Drag it in a few more times to make a forest.",
        ]),
        quiz("What is the stash for?", ["Reusing drawings in other frames and scenes", "Deleting frames", "Recording sound"], 0,
             "Draw it once, stash it, and reuse it as often as you like."),
    ]))

    # 6. Hair sway
    head_c, head_r = (CX, 0.34), 0.13

    def strands(t, n=7, length=0.42, amp=0.07, tip_only=False):
        out = []
        for i in range(n):
            a = math.pi * (1.1 + 0.8 * i / max(1, n - 1))
            root = (head_c[0] + head_r * math.cos(a), head_c[1] + head_r * math.sin(a))
            side = -1 if root[0] < head_c[0] else 1
            pts = []
            for k in range(13):
                u = k / 12
                wave = math.sin(TAU * t - 2.4 * u) + 0.3 * math.sin(TAU * 2 * t - 4 * u + 1.3)
                x = root[0] + side * 0.05 * u + amp * u * u * wave
                y = root[1] + length * u
                pts.append((x, y))
            out.append(pts)
        return out
    sway = []
    for k in range(12):
        t = k / 12
        sway.append(F([ink(circle(head_c[0], head_c[1], head_r, n=36), closed=True)] + [ink(s) for s in strands(t)]))
    one = []
    for k in range(12):
        t = k / 12
        s = strands(t, n=1, length=0.6, amp=0.12)[0]
        s = move(s, 0.0, -0.1)
        one.append(F([ink(s), dot(*s[0]), dot(*s[-1])], notes=[("roots", s[0][0] + 0.1, s[0][1]), ("tips", s[-1][0] + 0.1, s[-1][1])]))
    lessons.append(lesson("tools.hair", "Hair Sway", "Let Gale move hair for you.", [
        read("Hair that moves by itself",
             "Hair Sway makes hair move on its own. You circle the hair and draw a line where it grows from (the "
             "roots). Gale keeps the roots still and swings the tips the most, with a little wind and gusts, so it "
             "looks alive.", G(sway)),
        read("Roots stay, tips swing",
             "Look closely: the tips move a little later than the middle. That delay is what makes hair look soft. "
             "Stiff hair moves less and faster. Soft hair swings wide and slow.", G(one)),
        tool("Make hair sway", "Try Hair Sway on your own character.", "hairSway", [
            "Draw a character with long hair, with the hair on its own layer.",
            "Pick Hair Sway and circle the hair.",
            "Draw a line along the roots, where the hair meets the head.",
            "Play it. Try more wind, then more stiffness, and see how it changes.",
        ]),
        quiz("Which part of the hair moves the most?", ["The roots", "The tips", "They all move the same"], 1,
             "The roots are stuck to the head, so the tips swing the furthest."),
    ]))

    # 7. Motion blur
    blur = []
    for k in range(8):
        x = 0.15 + k * 0.15
        paths = [helper(circle(x - j * 0.035, 0.5, 0.07, n=24), closed=True) for j in (3, 2, 1)] if k > 0 else []
        paths.append(ball(x, 0.5))
        blur.append(F(paths))
    slow_fast = []
    for k in range(8):
        xs_ = 0.2 + k * 0.02
        xf = 0.15 + k * 0.15
        paths = [ball(xs_, 0.3, r=0.06)]
        paths += [helper(circle(xf - j * 0.035, 0.7, 0.06, n=24), closed=True) for j in (3, 2, 1)] if k > 0 else []
        paths.append(ball(xf, 0.7, r=0.06))
        slow_fast.append(F(paths, notes=[("slow: sharp", 0.5, 0.14), ("fast: blurred", 0.5, 0.88)]))
    lessons.append(lesson("tools.blur", "Motion Blur", "Make fast things feel fast.", [
        read("Speed you can see",
             "When something moves really fast, a camera sees a smear. Motion blur adds faded copies trailing "
             "behind fast things, so your animation feels quick and smooth instead of jumpy. Gale finds what moved "
             "and adds the trail for you.", G(blur, fps=10)),
        read("Only fast things",
             "Motion blur only shows on things that move a lot between frames. Slow things stay sharp. Too much "
             "blur makes things hard to see, so keep it subtle.", G(slow_fast, fps=10)),
        tool("Turn on motion blur", "Try motion blur on something fast.", "motionBlur", [
            "Animate a ball zooming across the screen in 4 frames.",
            "Turn on Motion Blur.",
            "Play it with the amount low, then high. Pick what looks best.",
        ]),
        quiz("Which needs motion blur the most?", ["A snail crawling", "A baseball after it's hit", "A sleeping cat"], 1,
             "The baseball moves a long way each frame, so a blur trail helps it read as fast."),
    ]))

    return course("tools", TRACK, "Gale's Tools", "Stabilizer, layers, onion skin and more", "wrench.and.screwdriver",
                  [], lessons)
