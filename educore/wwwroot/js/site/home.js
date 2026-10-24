// Public website (Views/Site/Index.cshtml).
// Three.js draws the glowing shape in the hero, GSAP + ScrollTrigger run the scroll effects.
// Both come from a CDN; if one is missing its part is skipped and the page stays fully readable.
(function () {
    var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var finePointer = window.matchMedia('(pointer: fine)').matches;
    var isDesktop = window.matchMedia('(min-width: 961px)').matches;
    var hasGsap = !!(window.gsap && window.ScrollTrigger);

    setUpNav();
    setUpReelPlayback();
    if (reduceMotion) {
        return;   // no 3D, no scroll effects: the CSS already shows everything
    }
    setUpHero3D();
    setUpCursorGlow();
    setUpTilt();
    setUpMagnetButtons();
    if (hasGsap) {
        gsap.registerPlugin(ScrollTrigger);
        setUpScrollAnimations();
    }

    // ───────────── top bar + phone menu + progress bar ─────────────
    function setUpNav() {
        var nav = document.getElementById('nav');
        var links = document.getElementById('navLinks');
        var burger = document.getElementById('navBurger');
        var progress = document.getElementById('progress');

        function onScroll() {
            nav.classList.toggle('scrolled', window.scrollY > 8);
            var max = document.documentElement.scrollHeight - window.innerHeight;
            progress.style.transform = 'scaleX(' + (max > 0 ? window.scrollY / max : 0) + ')';
        }
        window.addEventListener('scroll', onScroll, { passive: true });
        onScroll();

        burger.addEventListener('click', function () {
            var open = links.classList.toggle('open');
            burger.innerHTML = open ? '<i class="bx bx-x"></i>' : '<i class="bx bx-menu"></i>';
        });
        links.addEventListener('click', function (e) {
            if (e.target.tagName === 'A') {
                links.classList.remove('open');
                burger.innerHTML = '<i class="bx bx-menu"></i>';
            }
        });
    }

    // ───────────── reels animate only while they are on screen ─────────────
    function setUpReelPlayback() {
        var reels = document.querySelectorAll('[data-reel]');
        if (!('IntersectionObserver' in window)) {
            reels.forEach(function (r) { r.classList.add('play'); });
            return;
        }
        var watcher = new IntersectionObserver(function (entries) {
            entries.forEach(function (en) { en.target.classList.toggle('play', en.isIntersecting); });
        }, { threshold: 0.35 });
        reels.forEach(function (r) { watcher.observe(r); });
    }

    // ───────────── hero: 3D blob, wire shell, particle ring, floating shapes ─────────────
    function setUpHero3D() {
        var canvas = document.getElementById('heroCanvas');
        var hero = document.getElementById('hero');
        if (!canvas || !window.THREE) return;

        var renderer;
        try {
            renderer = new THREE.WebGLRenderer({ canvas: canvas, antialias: true, alpha: true });
        } catch (e) {
            return;   // no WebGL on this device: the hero keeps its gradient background
        }
        renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));

        var scene = new THREE.Scene();
        var camera = new THREE.PerspectiveCamera(45, 1, 0.1, 100);
        camera.position.set(0, 0, 6);

        // everything moves together inside this group (mouse tilt, scroll)
        var group = new THREE.Group();
        scene.add(group);

        // The blob: a sphere whose surface is pushed in and out by a few sine waves.
        // Colour goes from deep brown in the dips to orange/pink on the peaks, with a bright rim.
        var blobMaterial = new THREE.ShaderMaterial({
            uniforms: { uTime: { value: 0 } },
            vertexShader: [
                'uniform float uTime;',
                'varying float vWave;',
                'varying vec3 vNormal;',
                'varying vec3 vView;',
                'void main() {',
                '  vec3 p = position;',
                '  float w = sin(p.x * 2.2 + uTime * 1.1) * sin(p.y * 2.6 + uTime * 1.3) * sin(p.z * 2.0 + uTime * 0.9);',
                '  w += 0.5 * sin(p.x * 4.5 - uTime * 1.7) * sin(p.y * 4.0 + uTime * 1.2);',
                '  vWave = w;',
                '  p += normal * w * 0.22;',
                '  vec4 mv = modelViewMatrix * vec4(p, 1.0);',
                '  vNormal = normalize(normalMatrix * normal);',
                '  vView = normalize(-mv.xyz);',
                '  gl_Position = projectionMatrix * mv;',
                '}'
            ].join('\n'),
            fragmentShader: [
                'varying float vWave;',
                'varying vec3 vNormal;',
                'varying vec3 vView;',
                'void main() {',
                '  float rim = pow(1.0 - max(dot(vNormal, vView), 0.0), 2.0);',
                '  vec3 deep = vec3(0.22, 0.05, 0.03);',
                '  vec3 orange = vec3(1.0, 0.54, 0.0);',
                '  vec3 pink = vec3(1.0, 0.18, 0.49);',
                '  vec3 c = mix(deep, orange, smoothstep(-0.6, 0.6, vWave));',
                '  c = mix(c, pink, smoothstep(0.3, 1.0, vWave) * 0.65);',
                '  c += rim * vec3(1.0, 0.72, 0.45) * 1.3;',
                '  gl_FragColor = vec4(c, 1.0);',
                '}'
            ].join('\n')
        });
        var detail = isDesktop ? 160 : 90;
        var blob = new THREE.Mesh(new THREE.SphereGeometry(1.35, detail, detail), blobMaterial);
        group.add(blob);

        // thin wire shell around the blob
        var shell = new THREE.Mesh(
            new THREE.IcosahedronGeometry(2.05, 1),
            new THREE.MeshBasicMaterial({ color: 0xFF8A00, wireframe: true, transparent: true, opacity: 0.16 })
        );
        group.add(shell);

        // a flat ring of glowing dots, like a small galaxy
        var dotCount = isDesktop ? 2600 : 1200;
        var dots = new Float32Array(dotCount * 3);
        for (var i = 0; i < dotCount; i++) {
            var angle = Math.random() * Math.PI * 2;
            var radius = 2.3 + Math.random() * 1.6;
            dots[i * 3] = Math.cos(angle) * radius;
            dots[i * 3 + 1] = (Math.random() - 0.5) * 0.25;
            dots[i * 3 + 2] = Math.sin(angle) * radius;
        }
        var dotGeometry = new THREE.BufferGeometry();
        dotGeometry.setAttribute('position', new THREE.BufferAttribute(dots, 3));
        var ring = new THREE.Points(dotGeometry, new THREE.PointsMaterial({
            color: 0xFFB36B, size: 0.028, transparent: true, opacity: 0.85,
            blending: THREE.AdditiveBlending, depthWrite: false
        }));
        ring.rotation.x = 1.15;
        ring.rotation.z = 0.25;
        group.add(ring);

        // small shiny shapes floating around (a torus, a cube like a book, gems)
        scene.add(new THREE.AmbientLight(0xffffff, 0.35));
        var warmLight = new THREE.PointLight(0xFF8A00, 2.2, 20);
        warmLight.position.set(3, 3, 4);
        scene.add(warmLight);
        var pinkLight = new THREE.PointLight(0xFF2E7E, 1.8, 20);
        pinkLight.position.set(-4, -2, 3);
        scene.add(pinkLight);

        var shapes = [];
        addShape(new THREE.TorusGeometry(0.28, 0.1, 24, 60), 0xFFB300, 2.3, 1.2, 0.6);
        addShape(new THREE.BoxGeometry(0.42, 0.55, 0.12), 0xFF5E1A, -2.2, 1.0, 0.4);
        addShape(new THREE.OctahedronGeometry(0.3), 0xFF2E7E, -1.9, -1.3, 0.8);
        addShape(new THREE.IcosahedronGeometry(0.24), 0x8B5CF6, 2.0, -1.4, 0.5);
        addShape(new THREE.TorusKnotGeometry(0.18, 0.06, 80, 12), 0xFFD9B3, 0.3, 2.0, -0.6);

        function addShape(geometry, color, x, y, z) {
            var mesh = new THREE.Mesh(geometry, new THREE.MeshStandardMaterial({ color: color, metalness: 0.45, roughness: 0.25 }));
            mesh.position.set(x, y, z);
            mesh.userData.baseY = y;
            mesh.userData.speed = 0.5 + Math.random() * 0.6;
            group.add(mesh);
            shapes.push(mesh);
        }

        // where the group sits: right of the text on a computer, centred behind it on a phone
        function resize() {
            var w = hero.clientWidth;
            var h = hero.clientHeight;
            renderer.setSize(w, h, false);
            camera.aspect = w / h;
            camera.updateProjectionMatrix();
            if (w > 960) {
                group.userData.baseX = 2.4;
                group.userData.baseScale = 1;
            } else {
                group.userData.baseX = 0;
                group.userData.baseScale = 0.72;
            }
        }
        window.addEventListener('resize', resize);
        resize();

        // the mouse tilts the group a little
        var mouseX = 0, mouseY = 0;
        window.addEventListener('pointermove', function (e) {
            mouseX = e.clientX / window.innerWidth - 0.5;
            mouseY = e.clientY / window.innerHeight - 0.5;
        }, { passive: true });

        // stop drawing while the hero is off screen (saves the phone's battery)
        var heroVisible = true;
        if ('IntersectionObserver' in window) {
            new IntersectionObserver(function (entries) {
                heroVisible = entries[0].isIntersecting;
            }).observe(hero);
        }

        var clock = new THREE.Clock();
        function frame() {
            requestAnimationFrame(frame);
            if (!heroVisible) return;

            var t = clock.getElapsedTime();
            blobMaterial.uniforms.uTime.value = t;
            blob.rotation.y = t * 0.15;
            shell.rotation.y = -t * 0.08;
            shell.rotation.x = t * 0.05;
            ring.rotation.y = t * 0.06;

            for (var i = 0; i < shapes.length; i++) {
                var s = shapes[i];
                s.rotation.x = t * s.userData.speed;
                s.rotation.y = t * s.userData.speed * 0.8;
                s.position.y = s.userData.baseY + Math.sin(t * s.userData.speed + i) * 0.15;
            }

            // ease towards the mouse; as the page scrolls the group rises and shrinks away
            var scrolled = Math.min(window.scrollY / hero.clientHeight, 1);
            group.rotation.y += (mouseX * 0.6 - group.rotation.y) * 0.05;
            group.rotation.x += (mouseY * 0.4 - group.rotation.x) * 0.05;
            group.position.x = group.userData.baseX;
            group.position.y = scrolled * 1.8;
            var scale = group.userData.baseScale * (1 - scrolled * 0.35);
            group.scale.set(scale, scale, scale);

            renderer.render(scene, camera);
        }
        frame();

        // the notification chips drift against the mouse, by their own depth
        var chips = document.querySelectorAll('.chip');
        window.addEventListener('pointermove', function () {
            chips.forEach(function (chip) {
                var depth = Number(chip.getAttribute('data-depth'));
                chip.style.transform = 'translate(' + (-mouseX * depth) + 'px,' + (-mouseY * depth) + 'px)';
            });
        }, { passive: true });
    }

    // ───────────── a soft light that follows the mouse ─────────────
    function setUpCursorGlow() {
        var glow = document.getElementById('cursorGlow');
        if (!finePointer) return;
        var x = 0, y = 0, gx = 0, gy = 0;
        window.addEventListener('pointermove', function (e) {
            x = e.clientX;
            y = e.clientY;
            glow.classList.add('on');
        }, { passive: true });
        function follow() {
            gx += (x - gx) * 0.12;
            gy += (y - gy) * 0.12;
            glow.style.transform = 'translate(' + gx + 'px,' + gy + 'px)';
            requestAnimationFrame(follow);
        }
        follow();
    }

    // ───────────── cards lean towards the mouse ─────────────
    function setUpTilt() {
        if (!finePointer) return;
        document.querySelectorAll('.tilt').forEach(function (card) {
            card.addEventListener('pointermove', function (e) {
                var box = card.getBoundingClientRect();
                var px = (e.clientX - box.left) / box.width;
                var py = (e.clientY - box.top) / box.height;
                var strength = card.classList.contains('cta') ? 4 : 10;
                card.style.transform = 'perspective(900px) rotateX(' + ((0.5 - py) * strength) + 'deg) rotateY(' + ((px - 0.5) * strength) + 'deg) translateZ(0)';
                card.style.setProperty('--mx', (px * 100) + '%');
                card.style.setProperty('--my', (py * 100) + '%');
            });
            card.addEventListener('pointerleave', function () {
                card.style.transition = 'transform .5s ease';
                card.style.transform = '';
                setTimeout(function () { card.style.transition = ''; }, 500);
            });
        });
    }

    // ───────────── main buttons pull a little towards the mouse ─────────────
    function setUpMagnetButtons() {
        if (!finePointer) return;
        document.querySelectorAll('.magnet').forEach(function (btn) {
            btn.addEventListener('pointermove', function (e) {
                var box = btn.getBoundingClientRect();
                var dx = e.clientX - (box.left + box.width / 2);
                var dy = e.clientY - (box.top + box.height / 2);
                btn.style.transform = 'translate(' + (dx * 0.25) + 'px,' + (dy * 0.35) + 'px)';
            });
            btn.addEventListener('pointerleave', function () { btn.style.transform = ''; });
        });
    }

    // ───────────── scroll effects (GSAP) ─────────────
    function setUpScrollAnimations() {
        // hero headline rises line by line, the rest fades up after it
        gsap.from('.hero-h .ln > span', { yPercent: 110, duration: 1.1, ease: 'power4.out', stagger: 0.12, delay: 0.1 });
        gsap.from('.hero [data-up]', { y: 30, opacity: 0, duration: 0.9, ease: 'power3.out', stagger: 0.1, delay: 0.35 });
        gsap.from('.chip', { scale: 0.6, opacity: 0, duration: 0.8, ease: 'back.out(1.7)', stagger: 0.15, delay: 0.9 });

        // everything else marked data-up fades up as it comes into view
        document.querySelectorAll('[data-up]').forEach(function (el) {
            if (el.closest('.hero')) return;
            gsap.from(el, {
                y: 50, opacity: 0, duration: 0.9, ease: 'power3.out', clearProps: 'transform',
                scrollTrigger: { trigger: el, start: 'top 88%' }
            });
        });

        // module cards fly in with a 3D flip, one after another
        gsap.from('.mod', {
            y: 80, rotateX: -35, opacity: 0, duration: 0.9, ease: 'power3.out', stagger: 0.06, transformPerspective: 900, clearProps: 'transform',
            scrollTrigger: { trigger: '.mods', start: 'top 85%' }
        });

        // the product picture lies back in 3D and straightens up as you scroll
        gsap.fromTo('#showApp',
            { rotateX: 42, scale: 0.82, y: 40 },
            { rotateX: 0, scale: 1, y: 0, ease: 'none', scrollTrigger: { trigger: '.show-stage', start: 'top 95%', end: 'top 25%', scrub: 1 } });
        gsap.from('#showApp .bars i', {
            scaleY: 0, duration: 1, ease: 'power3.out', stagger: 0.07,
            scrollTrigger: { trigger: '.show-stage', start: 'top 45%' }
        });

        // numbers count up
        document.querySelectorAll('[data-count]').forEach(function (el) {
            var target = Number(el.getAttribute('data-count'));
            var counter = { value: 0 };
            gsap.to(counter, {
                value: target, duration: 1.6, ease: 'power2.out',
                scrollTrigger: { trigger: el, start: 'top 90%' },
                onUpdate: function () { el.textContent = Math.round(counter.value); }
            });
        });

        // the big "why" sentence lights up word by word
        var say = document.getElementById('bigSay');
        var words = say.textContent.trim().split(/\s+/);
        say.innerHTML = words.map(function (w) { return '<span class="wd">' + w + '</span>'; }).join(' ');
        gsap.to('#bigSay .wd', {
            opacity: 1, ease: 'none', stagger: 0.1,
            scrollTrigger: { trigger: say, start: 'top 80%', end: 'bottom 45%', scrub: true }
        });

        // the line between the four steps fills as you scroll
        gsap.fromTo('#stepsFill', { scaleX: 0 }, {
            scaleX: 1, ease: 'none',
            scrollTrigger: { trigger: '.steps-wrap', start: 'top 75%', end: 'bottom 60%', scrub: true }
        });

        // big footer word slides in from the side
        gsap.from('.foot-word', { xPercent: -15, opacity: 0, ease: 'none', scrollTrigger: { trigger: '.foot', start: 'top bottom', end: 'bottom bottom', scrub: true } });

        // reels: on a computer the section is pinned and the row of reels slides sideways
        // while you scroll down. On a phone the row is a normal swipe list (see CSS).
        if (isDesktop) {
            var track = document.getElementById('reelsTrack');
            var slideDistance = function () { return Math.max(track.scrollWidth - window.innerWidth + 48, 0); };
            gsap.to(track, {
                x: function () { return -slideDistance(); },
                ease: 'none',
                scrollTrigger: {
                    trigger: '#reels', start: 'top top',
                    end: function () { return '+=' + slideDistance(); },
                    pin: true, scrub: 1, invalidateOnRefresh: true
                }
            });
        }
        gsap.from('.reel', {
            y: 120, rotateY: -25, opacity: 0, duration: 1, ease: 'power3.out', stagger: 0.1, transformPerspective: 1000, clearProps: 'transform',
            scrollTrigger: { trigger: '#reels', start: 'top 70%' }
        });
    }
})();
