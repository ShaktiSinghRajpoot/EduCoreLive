// Public website hero (Views/Site/Index.cshtml, section #build).
//
// A school desk drawn with Three.js. Every object on it is a "piece" with two places:
//   start = somewhere random, floating and spinning (the school in a mess)
//   end   = its place on the desk (laptop keys in the keyboard, tiles on the screen, books stacked)
// The scroll position through the tall #build section (0 at the top, 1 at the bottom) moves each
// piece from start to end, each with its own small delay so they arrive one after another.
//
// All objects are built from simple boxes, cylinders and spheres, and every picture on them
// (dashboard, registers, phone screen) is drawn on a <canvas>, so there are no model files.
// If WebGL is missing or the visitor prefers reduced motion this file does nothing and the
// section stays a plain hero (see .has3d in home.css).
(function () {
    var section = document.getElementById('build');
    var canvas = document.getElementById('buildCanvas');
    if (!section || !canvas || !window.THREE) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

    var renderer;
    try {
        renderer = new THREE.WebGLRenderer({ canvas: canvas, antialias: true, alpha: true });
    } catch (e) {
        return;
    }
    document.documentElement.classList.add('has3d');

    var isDesktop = window.matchMedia('(min-width: 961px)').matches;
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, isDesktop ? 2 : 1.5));
    renderer.shadowMap.enabled = isDesktop;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;

    var scene = new THREE.Scene();
    var camera = new THREE.PerspectiveCamera(40, 1, 0.1, 200);
    var FLOOR_Y = -0.08;          // the desk top; the laptop base sits on it
    var pieces = [];

    // ───────────── lights + the shadow on the desk ─────────────
    scene.add(new THREE.HemisphereLight(0xFFF4E8, 0x2A1A10, 0.85));
    var sun = new THREE.DirectionalLight(0xFFE2C4, 0.9);
    sun.position.set(4, 9, 6);
    sun.castShadow = true;
    sun.shadow.mapSize.set(1024, 1024);
    sun.shadow.bias = -0.0005;
    sun.shadow.camera.left = -8; sun.shadow.camera.right = 8;
    sun.shadow.camera.top = 8; sun.shadow.camera.bottom = -8;
    scene.add(sun);
    var rimLight = new THREE.PointLight(0xFF2E7E, 1.2, 30);
    rimLight.position.set(-6, 3, -5);
    scene.add(rimLight);
    var warmLight = new THREE.PointLight(0xFF8A00, 1.0, 30);
    warmLight.position.set(6, 2, 4);
    scene.add(warmLight);

    var floorMaterial = new THREE.ShadowMaterial({ opacity: 0 });
    var floor = new THREE.Mesh(new THREE.PlaneGeometry(40, 40), floorMaterial);
    floor.rotation.x = -Math.PI / 2;
    floor.position.y = FLOOR_Y - 0.001;
    floor.receiveShadow = true;
    scene.add(floor);

    // ───────────── canvas drawing helpers ─────────────
    function makeCanvas(width, height) {
        var c = document.createElement('canvas');
        c.width = width;
        c.height = height;
        return c;
    }

    function roundRect(ctx, x, y, w, h, r) {
        ctx.beginPath();
        ctx.moveTo(x + r, y);
        ctx.arcTo(x + w, y, x + w, y + h, r);
        ctx.arcTo(x + w, y + h, x, y + h, r);
        ctx.arcTo(x, y + h, x, y, r);
        ctx.arcTo(x, y, x + w, y, r);
        ctx.closePath();
    }

    function toTexture(c) {
        var texture = new THREE.CanvasTexture(c);
        texture.anisotropy = renderer.capabilities.getMaxAnisotropy();
        return texture;
    }

    var FONT = '"Segoe UI", Inter, Arial, sans-serif';

    // ───────────── the laptop screen and its dashboard tiles ─────────────
    // Screen size in 3D units, and the six tile slots on it (centre x, y in screen units).
    var SCREEN_W = 3.95, SCREEN_H = 2.5;
    var TILE_W = 1.087, TILE_H = 0.915, TILE_GAP = 0.12;
    var TILE_LEFT = -1.55, TILE_TOP = 0.78;
    var tileSlots = [];
    for (var row = 0; row < 2; row++) {
        for (var col = 0; col < 3; col++) {
            tileSlots.push({
                x: TILE_LEFT + TILE_W / 2 + col * (TILE_W + TILE_GAP),
                y: TILE_TOP - TILE_H / 2 - row * (TILE_H + TILE_GAP)
            });
        }
    }

    // screen units -> pixels on the 1024 x 648 screen canvas
    function screenPxX(x) { return (x + SCREEN_W / 2) / SCREEN_W * 1024; }
    function screenPxY(y) { return (SCREEN_H / 2 - y) / SCREEN_H * 648; }

    function drawScreen() {
        var c = makeCanvas(1024, 648);
        var ctx = c.getContext('2d');
        ctx.fillStyle = '#FFFBF6';
        ctx.fillRect(0, 0, 1024, 648);

        // dark side menu with the orange "active" item
        ctx.fillStyle = '#17100B';
        ctx.fillRect(0, 0, 90, 648);
        ctx.fillStyle = '#FF8A00';
        roundRect(ctx, 22, 22, 46, 46, 12); ctx.fill();
        for (var i = 0; i < 7; i++) {
            ctx.fillStyle = i === 0 ? '#FF5E1A' : '#3A2C22';
            roundRect(ctx, 30, 104 + i * 62, 30, 30, 8); ctx.fill();
        }

        // header
        ctx.fillStyle = '#1D140E';
        ctx.font = 'bold 30px ' + FONT;
        ctx.fillText('Good morning, Principal', 118, 52);
        ctx.fillStyle = '#7C7168';
        ctx.font = '20px ' + FONT;
        ctx.fillText('SmartSchoolWala · Today at a glance', 118, 82);
        ctx.fillStyle = '#F1E7DC';
        roundRect(ctx, 780, 30, 210, 40, 20); ctx.fill();

        // empty dashed slots that the tiles fly into
        ctx.strokeStyle = '#E2D3C3';
        ctx.lineWidth = 3;
        ctx.setLineDash([12, 10]);
        for (var s = 0; s < tileSlots.length; s++) {
            var x = screenPxX(tileSlots[s].x - TILE_W / 2);
            var y = screenPxY(tileSlots[s].y + TILE_H / 2);
            roundRect(ctx, x, y, TILE_W / SCREEN_W * 1024, TILE_H / SCREEN_H * 648, 18);
            ctx.stroke();
        }
        return toTexture(c);
    }

    function drawTile(title, value, note, color) {
        var c = makeCanvas(512, 432);
        var ctx = c.getContext('2d');
        ctx.fillStyle = '#FFFFFF';
        roundRect(ctx, 4, 4, 504, 424, 36); ctx.fill();
        ctx.strokeStyle = '#EFE7DD';
        ctx.lineWidth = 6;
        ctx.stroke();
        ctx.fillStyle = color;
        roundRect(ctx, 36, 40, 72, 72, 20); ctx.fill();
        ctx.fillStyle = '#7C7168';
        ctx.font = '600 38px ' + FONT;
        ctx.fillText(title, 36, 180);
        ctx.fillStyle = '#1D140E';
        ctx.font = '800 76px ' + FONT;
        ctx.fillText(value, 36, 275);
        ctx.fillStyle = '#12A150';
        ctx.font = '600 32px ' + FONT;
        ctx.fillText(note, 36, 340);
        // a few small bars at the bottom
        for (var i = 0; i < 7; i++) {
            ctx.fillStyle = i === 6 ? color : '#F3E6D8';
            var h = 20 + ((i * 37) % 40);
            roundRect(ctx, 300 + i * 28, 395 - h, 18, h, 5); ctx.fill();
        }
        return toTexture(c);
    }

    function drawPhoneScreen() {
        var c = makeCanvas(400, 800);
        var ctx = c.getContext('2d');
        ctx.fillStyle = '#FFFBF6';
        ctx.fillRect(0, 0, 400, 800);
        var band = ctx.createLinearGradient(0, 0, 400, 0);
        band.addColorStop(0, '#FF8A00');
        band.addColorStop(1, '#FF2E7E');
        ctx.fillStyle = band;
        ctx.fillRect(0, 0, 400, 170);
        ctx.fillStyle = '#FFFFFF';
        ctx.font = 'bold 40px ' + FONT;
        ctx.fillText('Class 5-A', 30, 95);
        ctx.font = '24px ' + FONT;
        ctx.fillText('Attendance · Today', 30, 135);

        var names = ['Aarav Sharma', 'Diya Verma', 'Kabir Singh', 'Meera Joshi', 'Rohan Gupta', 'Sara Khan'];
        for (var i = 0; i < names.length; i++) {
            var y = 200 + i * 82;
            ctx.fillStyle = '#FFFFFF';
            roundRect(ctx, 20, y, 360, 66, 16); ctx.fill();
            ctx.fillStyle = '#1D140E';
            ctx.font = '600 24px ' + FONT;
            ctx.fillText(names[i], 40, y + 42);
            var absent = i === 4;
            ctx.fillStyle = absent ? '#EF4444' : '#22C55E';
            roundRect(ctx, 312, y + 13, 50, 40, 10); ctx.fill();
            ctx.fillStyle = '#FFFFFF';
            ctx.font = 'bold 24px ' + FONT;
            ctx.fillText(absent ? 'A' : 'P', 328, y + 42);
        }
        ctx.fillStyle = '#DCF8C6';
        roundRect(ctx, 20, 700, 360, 76, 18); ctx.fill();
        ctx.fillStyle = '#0B3B1C';
        ctx.font = '600 22px ' + FONT;
        ctx.fillText('WhatsApp sent to Rohan\'s parent', 38, 746);
        return toTexture(c);
    }

    function drawPaper(title, inkColor) {
        var c = makeCanvas(512, 700);
        var ctx = c.getContext('2d');
        ctx.fillStyle = '#FBF3E4';
        ctx.fillRect(0, 0, 512, 700);
        ctx.strokeStyle = '#B9CBE6';
        ctx.lineWidth = 2;
        for (var y = 120; y < 690; y += 38) {
            ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(512, y); ctx.stroke();
        }
        ctx.strokeStyle = '#E88A8A';
        ctx.beginPath(); ctx.moveTo(64, 0); ctx.lineTo(64, 700); ctx.stroke();
        ctx.fillStyle = '#2B2B6B';
        ctx.font = 'bold 40px ' + FONT;
        ctx.fillText(title, 80, 80);

        // "handwriting": wobbly ink lines of different lengths
        ctx.strokeStyle = inkColor;
        ctx.lineWidth = 3;
        for (var line = 0; line < 14; line++) {
            var baseY = 150 + line * 38 - 8;
            var length = 160 + ((line * 97) % 260);
            ctx.beginPath();
            ctx.moveTo(80, baseY);
            for (var x = 80; x < 80 + length; x += 14) {
                ctx.lineTo(x, baseY + Math.sin(x * 0.3 + line) * 5);
            }
            ctx.stroke();
        }
        return toTexture(c);
    }

    function drawCoinFace() {
        var c = makeCanvas(256, 256);
        var ctx = c.getContext('2d');
        ctx.fillStyle = '#F5B82E';
        ctx.fillRect(0, 0, 256, 256);
        ctx.strokeStyle = '#C98A10';
        ctx.lineWidth = 12;
        ctx.beginPath(); ctx.arc(128, 128, 104, 0, Math.PI * 2); ctx.stroke();
        ctx.fillStyle = '#B07508';
        ctx.font = 'bold 150px ' + FONT;
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText('₹', 128, 136);
        return toTexture(c);
    }

    // ───────────── materials ─────────────
    function plain(color, roughness, metalness) {
        return new THREE.MeshStandardMaterial({ color: color, roughness: roughness, metalness: metalness || 0 });
    }
    var silver = plain(0xC9CED6, 0.35, 0.6);
    var keyMaterial = plain(0x2A2A2E, 0.6);
    var orangeKey = plain(0xFF6B1A, 0.45);

    // ───────────── pieces ─────────────
    // A piece is placed at its END (on the desk) first; addPiece remembers that and picks a
    // random START, so every object is written down once, where it belongs.
    var startSpreadX = 18, startSpreadY = 9;

    function addPiece(object, delay) {
        object.updateMatrix();
        var spin = new THREE.Euler(Math.random() * 6.3, Math.random() * 6.3, Math.random() * 6.3);
        object.userData = {
            endPos: object.position.clone(),
            endQuat: object.quaternion.clone(),
            startPos: new THREE.Vector3(
                (Math.random() - 0.5) * startSpreadX,
                (Math.random() - 0.5) * startSpreadY + 0.6,
                (Math.random() - 0.5) * 9 - 1),
            startSpin: spin,
            spinSpeed: 0.2 + Math.random() * 0.5,
            wobble: Math.random() * 6.3,
            delay: delay
        };
        object.traverse(function (child) {
            if (child.isMesh) { child.castShadow = true; child.receiveShadow = true; }
        });
        scene.add(object);
        pieces.push(object);
    }

    function randomBetween(a, b) { return a + Math.random() * (b - a); }

    function buildScene() {
        // on a tall phone screen the mess spreads up and down instead of sideways
        var aspect = section.clientWidth / window.innerHeight;
        if (aspect < 1) { startSpreadX = 9; startSpreadY = 16; }

        // laptop base
        var base = new THREE.Mesh(new THREE.BoxGeometry(4.2, 0.16, 2.8), silver);
        addPiece(base, 0);

        // keyboard: 4 rows of 12 keys and a space bar
        var keyGeometry = new THREE.BoxGeometry(0.26, 0.06, 0.26);
        for (var r = 0; r < 4; r++) {
            for (var k = 0; k < 12; k++) {
                var isEnter = r === 2 && k === 11;
                var key = new THREE.Mesh(keyGeometry, isEnter ? orangeKey : keyMaterial);
                key.position.set(-1.65 + k * 0.3, 0.11, -0.95 + r * 0.3);
                addPiece(key, randomBetween(0.12, 0.45));
            }
        }
        var space = new THREE.Mesh(new THREE.BoxGeometry(1.8, 0.06, 0.26), keyMaterial);
        space.position.set(0, 0.11, 0.27);
        addPiece(space, 0.4);
        var trackpad = new THREE.Mesh(new THREE.BoxGeometry(1.3, 0.012, 0.75), plain(0xB4BAC4, 0.3, 0.5));
        trackpad.position.set(0, 0.085, 0.92);
        addPiece(trackpad, 0.15);

        // lid, opened and tipped back a little, with the screen on its front
        var tilt = 0.22;
        var lid = new THREE.Group();
        lid.add(new THREE.Mesh(new THREE.BoxGeometry(4.2, 2.7, 0.1), silver));
        var screen = new THREE.Mesh(new THREE.PlaneGeometry(SCREEN_W, SCREEN_H), new THREE.MeshBasicMaterial({ map: drawScreen() }));
        screen.position.z = 0.051;
        lid.add(screen);
        lid.position.set(0, 0.08 + 1.35 * Math.cos(tilt), -1.38 - 1.35 * Math.sin(tilt));
        lid.rotation.x = -tilt;
        addPiece(lid, 0.08);

        // the six dashboard tiles land in their slots on the screen
        lid.updateMatrixWorld(true);
        var tiles = [
            ['Students', '1,240', '+38 this session', '#FF8A00'],
            ['Present today', '96.4%', '1,195 marked', '#22C55E'],
            ['Fees today', '₹1,86,400', '74 receipts', '#FF5E1A'],
            ['Results', 'Class 10', 'Report cards ready', '#8B5CF6'],
            ['Transport', '6 routes', '248 riders', '#0EA5A4'],
            ['Salary', 'October', 'Payslips ready', '#FF2E7E']
        ];
        var tileGeometry = new THREE.PlaneGeometry(TILE_W, TILE_H);
        for (var t = 0; t < tiles.length; t++) {
            var tile = new THREE.Mesh(tileGeometry, new THREE.MeshBasicMaterial({
                map: drawTile(tiles[t][0], tiles[t][1], tiles[t][2], tiles[t][3]), side: THREE.DoubleSide
            }));
            tile.position.copy(lid.localToWorld(new THREE.Vector3(tileSlots[t].x, tileSlots[t].y, 0.064)));
            tile.quaternion.copy(lid.quaternion);
            addPiece(tile, 0.42 + t * 0.025);
        }

        // books stacked on the left, a graduation cap on top
        var bookColors = [0x2F6FE0, 0xE2412B, 0x12A150];
        for (var b = 0; b < 3; b++) {
            var book = new THREE.Group();
            book.add(new THREE.Mesh(new THREE.BoxGeometry(1.5, 0.28, 2.0), plain(bookColors[b], 0.7)));
            var pages = new THREE.Mesh(new THREE.BoxGeometry(1.42, 0.22, 1.9), plain(0xFFF8EC, 0.9));
            pages.position.x = 0.06;
            book.add(pages);
            book.position.set(-3.55, FLOOR_Y + 0.14 + b * 0.28, 0.25);
            book.rotation.y = 0.25 - b * 0.18;
            addPiece(book, randomBetween(0.05, 0.3));
        }
        var cap = new THREE.Group();
        cap.add(new THREE.Mesh(new THREE.CylinderGeometry(0.4, 0.42, 0.3, 32), plain(0x1E1E26, 0.6)));
        var board = new THREE.Mesh(new THREE.BoxGeometry(1.2, 0.05, 1.2), plain(0x1E1E26, 0.6));
        board.position.y = 0.17;
        cap.add(board);
        var tassel = new THREE.Mesh(new THREE.CylinderGeometry(0.025, 0.025, 0.5, 8), plain(0xF5B82E, 0.4, 0.3));
        tassel.position.set(0.55, -0.05, 0.3);
        cap.add(tassel);
        cap.position.set(-3.55, FLOOR_Y + 0.84 + 0.15, 0.25);
        cap.rotation.y = 0.6;
        addPiece(cap, 0.35);

        // registers (paper) stacked at the front left
        var papers = [['Attendance Register', '#1F3B8A'], ['Fee Receipts', '#8A1F1F'], ['Marks Sheet', '#1F6B3A']];
        var paperGeometry = new THREE.PlaneGeometry(1.1, 1.5);
        for (var p = 0; p < papers.length; p++) {
            var sheet = new THREE.Mesh(paperGeometry, new THREE.MeshStandardMaterial({
                map: drawPaper(papers[p][0], papers[p][1]), color: 0xD9CFC0, roughness: 0.9, side: THREE.DoubleSide
            }));
            sheet.rotation.set(-Math.PI / 2, 0, -0.35 + p * 0.18);
            sheet.position.set(-3.1, FLOOR_Y + 0.005 + p * 0.01, 1.95);
            addPiece(sheet, randomBetween(0.1, 0.35));
        }

        // a small stack of ₹ coins
        var coinFace = new THREE.MeshStandardMaterial({ map: drawCoinFace(), roughness: 0.35, metalness: 0.5 });
        var coinEdge = plain(0xD99A1A, 0.35, 0.6);
        var coinGeometry = new THREE.CylinderGeometry(0.24, 0.24, 0.08, 40);
        for (var c = 0; c < 4; c++) {
            var coin = new THREE.Mesh(coinGeometry, [coinEdge, coinFace, coinFace]);
            coin.position.set(-2.15 + (c % 2) * 0.03, FLOOR_Y + 0.04 + c * 0.08, 2.15);
            addPiece(coin, randomBetween(0.2, 0.5));
        }

        // phone lying on the right, showing attendance
        var phone = new THREE.Group();
        phone.add(new THREE.Mesh(new THREE.BoxGeometry(0.82, 0.06, 1.64), plain(0x111114, 0.4, 0.3)));
        var phoneScreen = new THREE.Mesh(new THREE.PlaneGeometry(0.74, 1.48), new THREE.MeshBasicMaterial({ map: drawPhoneScreen() }));
        phoneScreen.rotation.x = -Math.PI / 2;
        phoneScreen.position.y = 0.031;
        phone.add(phoneScreen);
        phone.position.set(3.25, FLOOR_Y + 0.03, 0.1);
        phone.rotation.y = -0.3;
        addPiece(phone, 0.3);

        // pencils at the front right
        var pencilColors = [0xFFC233, 0xFF5E1A, 0x2F6FE0];
        for (var n = 0; n < 3; n++) {
            var pencil = new THREE.Group();
            pencil.add(new THREE.Mesh(new THREE.CylinderGeometry(0.05, 0.05, 1.2, 6), plain(pencilColors[n], 0.5)));
            var tip = new THREE.Mesh(new THREE.ConeGeometry(0.05, 0.2, 6), plain(0xE8C9A0, 0.8));
            tip.position.y = 0.7;
            pencil.add(tip);
            var eraser = new THREE.Mesh(new THREE.CylinderGeometry(0.05, 0.05, 0.12, 12), plain(0xFF8FA3, 0.7));
            eraser.position.y = -0.66;
            pencil.add(eraser);
            pencil.rotation.set(0, 0.15 - n * 0.08, Math.PI / 2);
            pencil.position.set(3.3, FLOOR_Y + 0.05, 1.3 + n * 0.22);
            addPiece(pencil, randomBetween(0.15, 0.45));
        }

        // apple for the teacher
        var apple = new THREE.Group();
        apple.add(new THREE.Mesh(new THREE.SphereGeometry(0.3, 32, 24), plain(0xD7262E, 0.35)));
        var stem = new THREE.Mesh(new THREE.CylinderGeometry(0.02, 0.02, 0.16, 6), plain(0x5A3A1A, 0.8));
        stem.position.y = 0.33;
        apple.add(stem);
        var leaf = new THREE.Mesh(new THREE.SphereGeometry(0.1, 12, 8), plain(0x3FA34D, 0.6));
        leaf.scale.set(1, 0.3, 0.5);
        leaf.position.set(0.09, 0.36, 0);
        apple.add(leaf);
        apple.position.set(2.2, FLOOR_Y + 0.3, 2.05);
        addPiece(apple, 0.25);

        // school bag at the back right
        var bag = new THREE.Group();
        bag.add(new THREE.Mesh(new THREE.BoxGeometry(1.3, 1.6, 0.7), plain(0xFF6B1A, 0.75)));
        var pocket = new THREE.Mesh(new THREE.BoxGeometry(1.0, 0.7, 0.16), plain(0xE2541F, 0.75));
        pocket.position.set(0, -0.35, 0.42);
        bag.add(pocket);
        var handle = new THREE.Mesh(new THREE.TorusGeometry(0.28, 0.05, 10, 24, Math.PI), plain(0x2A1A10, 0.6));
        handle.position.y = 0.8;
        bag.add(handle);
        bag.position.set(3.6, FLOOR_Y + 0.8, -1.5);
        bag.rotation.y = -0.5;
        addPiece(bag, 0.2);

        // toy school bus at the back left
        var bus = new THREE.Group();
        bus.add(new THREE.Mesh(new THREE.BoxGeometry(1.3, 0.55, 0.6), plain(0xFFC233, 0.5)));
        var windows = new THREE.Mesh(new THREE.BoxGeometry(1.1, 0.18, 0.62), plain(0x1E2A38, 0.2, 0.3));
        windows.position.set(-0.05, 0.1, 0);
        bus.add(windows);
        var wheelGeometry = new THREE.CylinderGeometry(0.12, 0.12, 0.08, 20);
        var wheelMaterial = plain(0x1A1A1A, 0.8);
        var wheelSpots = [[-0.4, 0.31], [0.4, 0.31], [-0.4, -0.31], [0.4, -0.31]];
        for (var w = 0; w < wheelSpots.length; w++) {
            var wheel = new THREE.Mesh(wheelGeometry, wheelMaterial);
            wheel.rotation.x = Math.PI / 2;
            wheel.position.set(wheelSpots[w][0], -0.275, wheelSpots[w][1]);
            bus.add(wheel);
        }
        bus.position.set(-3.4, FLOOR_Y + 0.12 + 0.275, -1.5);
        bus.rotation.y = 0.5;
        addPiece(bus, 0.3);
    }

    // ───────────── camera path: far and messy -> circling the laptop -> desk beside the text ─────────────
    var camStart = {}, camMid = {}, camEnd = {};
    var TAN = Math.tan(THREE.MathUtils.degToRad(20));   // half of the 40° field of view

    // a camera stop = the point looked at + the camera position, at a given distance along a direction
    function cameraStop(lookX, lookY, lookZ, dirX, dirY, dirZ, distance) {
        var dir = new THREE.Vector3(dirX, dirY, dirZ).normalize();
        var look = new THREE.Vector3(lookX, lookY, lookZ);
        return { look: look, pos: look.clone().add(dir.multiplyScalar(distance)) };
    }

    function resize() {
        var width = section.clientWidth;
        var height = window.innerHeight;
        renderer.setSize(width, height, false);
        camera.aspect = width / height;
        camera.updateProjectionMatrix();

        var aspect = camera.aspect;
        var startDist = Math.max(15, 4.5 / (TAN * aspect));
        var midDist = Math.max(9.5, 5.6 / (TAN * aspect));
        camStart = cameraStop(0, 0.5, 0, 0, 0.08, 1, startDist);
        camMid = cameraStop(0, 0.8, 0, 0.5, 0.42, 0.8, midDist);

        if (aspect > 1.1) {
            // computer: the desk sits in the right part of the screen, the text on the left
            var endDist = Math.max(13, 9.4 / (TAN * aspect));
            var halfWidth = TAN * endDist * aspect;
            camEnd = cameraStop(-0.4 * halfWidth, 0.7, 0, 0, 0.3, 1, endDist);
        } else {
            // phone: the desk sits in the top part of the screen, the text below it
            var phoneDist = 5.4 / (TAN * aspect);
            camEnd = cameraStop(0, -0.5 * TAN * phoneDist, 0, 0, 0.3, 1, phoneDist);
        }
    }

    // ───────────── scroll position + captions ─────────────
    var captions = section.querySelectorAll('.cap');
    var targetProgress = 0, progress = 0;

    function readScroll() {
        var box = section.getBoundingClientRect();
        var room = section.offsetHeight - window.innerHeight;
        targetProgress = room > 0 ? clamp(-box.top / room, 0, 1) : 0;
    }

    // each caption shows between its data-from and data-to, fading over 0.05 at both ends
    function updateCaptions(p) {
        captions.forEach(function (cap) {
            var from = Number(cap.getAttribute('data-from'));
            var to = Number(cap.getAttribute('data-to'));
            var fadeIn = from === 0 ? 1 : clamp((p - from) / 0.05, 0, 1);
            var fadeOut = clamp((to - p) / 0.05, 0, 1);
            var shown = Math.min(fadeIn, fadeOut);
            cap.style.opacity = shown;
            cap.classList.toggle('on', shown > 0.5);
            var lift = (1 - shown) * 30;
            cap.style.translate = '0 ' + lift + 'px';
        });
    }

    function clamp(v, min, max) { return Math.min(Math.max(v, min), max); }
    function ease(t) { return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; }

    // ───────────── every frame ─────────────
    var mouseX = 0, mouseY = 0;
    var tmpQuat = new THREE.Quaternion();
    var tmpEuler = new THREE.Euler();
    var look = new THREE.Vector3();
    var clock = new THREE.Clock();
    var visible = true;

    function frame() {
        requestAnimationFrame(frame);
        if (!visible) return;

        var time = clock.getElapsedTime();
        progress += (targetProgress - progress) * 0.08;   // smooth out the scroll steps
        updateCaptions(progress);

        // 0..1 for the whole assembly; each piece then waits for its own delay
        var assembled = clamp((progress - 0.05) / 0.72, 0, 1);
        for (var i = 0; i < pieces.length; i++) {
            var piece = pieces[i];
            var d = piece.userData;
            var t = ease(clamp((assembled - d.delay) / 0.45, 0, 1));
            var loose = 1 - t;

            // fly from start to end along a little arc, floating gently while still loose
            piece.position.lerpVectors(d.startPos, d.endPos, t);
            piece.position.y += Math.sin(t * Math.PI) * 1.2 + Math.sin(time * 0.8 + d.wobble) * 0.25 * loose;

            // spin while loose, then turn smoothly into the final angle
            tmpEuler.set(d.startSpin.x + time * d.spinSpeed, d.startSpin.y + time * d.spinSpeed * 0.7, d.startSpin.z);
            tmpQuat.setFromEuler(tmpEuler);
            piece.quaternion.copy(tmpQuat).slerp(d.endQuat, t);
        }
        floorMaterial.opacity = 0.4 * clamp((assembled - 0.6) / 0.4, 0, 1);

        // camera: start -> mid over the first half, mid -> end over the rest
        var from, to, k;
        if (progress < 0.5) { from = camStart; to = camMid; k = ease(progress / 0.5); }
        else { from = camMid; to = camEnd; k = ease(clamp((progress - 0.5) / 0.42, 0, 1)); }
        camera.position.lerpVectors(from.pos, to.pos, k);
        look.lerpVectors(from.look, to.look, k);
        camera.position.x += mouseX * 0.8;
        camera.position.y -= mouseY * 0.5;
        camera.lookAt(look);

        renderer.render(scene, camera);
    }

    buildScene();
    resize();
    readScroll();
    progress = targetProgress;
    window.addEventListener('resize', function () { resize(); readScroll(); });
    window.addEventListener('scroll', readScroll, { passive: true });
    window.addEventListener('pointermove', function (e) {
        mouseX = e.clientX / window.innerWidth - 0.5;
        mouseY = e.clientY / window.innerHeight - 0.5;
    }, { passive: true });

    // stop drawing once the section is scrolled past (saves the phone's battery)
    if ('IntersectionObserver' in window) {
        new IntersectionObserver(function (entries) {
            visible = entries[0].isIntersecting;
        }).observe(section);
    }
    frame();
})();
