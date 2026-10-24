// Public website (Views/Site/Index.cshtml).
// GSAP + ScrollTrigger run the scroll effects; the 3D hero is in assemble3d.js.
// GSAP comes from a CDN; if one is missing its part is skipped and the page stays fully readable.
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
        // everything marked data-up fades up as it comes into view
        document.querySelectorAll('[data-up]').forEach(function (el) {
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
