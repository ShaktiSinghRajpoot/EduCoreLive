// Public website (Views/Site/Index.cshtml).
// GSAP + ScrollTrigger run only the hero assembly (setUpAssembly). Everything else is plain:
// the phone menu, a fade-in as blocks come into view, and the demo form.
// GSAP comes from a CDN; if it is missing the hero simply shows the finished laptop.
(function () {
    var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var isDesktop = window.matchMedia('(min-width: 961px)').matches;
    var hasGsap = !!(window.gsap && window.ScrollTrigger);

    setUpNav();
    setUpEnquiryForm();
    if (reduceMotion) {
        return;   // no motion: the CSS already shows everything
    }
    setUpReveal();
    if (hasGsap) {
        gsap.registerPlugin(ScrollTrigger);
        // a phone's address bar showing/hiding must not re-measure the hero mid-scroll
        ScrollTrigger.config({ ignoreMobileResize: true });
        setUpAssembly();
    }

    // ───────────── hero: the loose pieces fly into the laptop as you scroll ─────────────
    // Each piece (.pc) sits in its final place on the laptop screen. At the top of the page
    // it is moved away to a spot on the screen given by data-at ("x%,y%" of the window),
    // tilted by data-r degrees, and shows its loose object (.obj). Scrolling brings it back
    // to its place, where the object fades into the dashboard tile (.tile).
    function setUpAssembly() {
        var build = document.getElementById('build');
        var lap = document.getElementById('lap');
        var stage = build.querySelector('.build-stage');
        var pieces = Array.prototype.slice.call(build.querySelectorAll('.pc'));
        document.documentElement.classList.add('assembling');

        // how far a piece must move from its place to sit at its starting spot. Measured with the
        // piece and the laptop un-moved (as they are once assembled), then put back as they were.
        function offset(piece, axis) {
            var at = piece.getAttribute('data-at').split(',');
            var pieceWas = piece.style.transform, lapWas = lap.style.transform;
            piece.style.transform = 'none';
            lap.style.transform = 'none';
            var box = piece.getBoundingClientRect();
            var area = stage.getBoundingClientRect();   // the stage is the size of the window
            piece.style.transform = pieceWas;
            lap.style.transform = lapWas;
            if (axis === 'x') return area.width * Number(at[0]) / 100 - (box.left - area.left + box.width / 2);
            return area.height * Number(at[1]) / 100 - (box.top - area.top + box.height / 2);
        }

        var tl = gsap.timeline({
            defaults: { ease: 'power2.inOut' },
            scrollTrigger: {
                // scrub: true = the pieces follow the scrollbar exactly. A smoothing delay left pieces
                // half-way on a fast scroll while the captions had already moved on.
                trigger: build, start: 'top top', end: 'bottom bottom', scrub: true, invalidateOnRefresh: true,
                onUpdate: function (st) { showCaptions(st.progress); }
            }
        });

        // the laptop comes up from a tilt and switches on
        tl.fromTo(lap, { rotateX: 30, scale: 0.8, transformPerspective: 1400 }, { rotateX: 0, scale: 1, duration: 0.2 }, 0);
        tl.to('.scr-off', { opacity: 0, duration: 0.08 }, 0.12);

        // the pieces, one after another
        pieces.forEach(function (piece, i) {
            var start = 0.2 + i * 0.055;
            // functions so the distances are measured again when the window is resized;
            // the laptop is at its final size here, because a fromTo starts from the end state
            tl.fromTo(piece,
                {
                    x: function () { return offset(piece, 'x'); },
                    y: function () { return offset(piece, 'y'); },
                    rotation: Number(piece.getAttribute('data-r') || 0)
                },
                { x: 0, y: 0, rotation: 0, duration: 0.22 }, start);
            var obj = piece.querySelector('.obj');
            var tile = piece.querySelector('.tile');
            if (tile) {
                tl.fromTo(obj, { opacity: 1 }, { opacity: 0, duration: 0.05, ease: 'none' }, start + 0.17);
                tl.fromTo(tile, { opacity: 0 }, { opacity: 1, duration: 0.05, ease: 'none' }, start + 0.17);
            }
        });

        // the finished laptop moves aside for the last caption (up on a phone, right on a computer)
        tl.to(lap, isDesktop
            ? { x: function () { return window.innerWidth * 0.2; }, scale: 0.9, duration: 0.12 }
            : { y: function () { return -window.innerHeight * 0.06; }, scale: 0.92, duration: 0.12 }, 0.8);
        tl.to({}, { duration: 0.08 });   // a short rest at the end before the page moves on

        // captions fade in and out over their data-from..data-to part of the scroll
        var caps = Array.prototype.slice.call(build.querySelectorAll('.cap'));
        function showCaptions(p) {
            caps.forEach(function (cap) {
                var from = Number(cap.getAttribute('data-from'));
                var to = Number(cap.getAttribute('data-to'));
                var fade = 0.04;
                var o = Math.min(1, Math.max(0, (p - from) / fade), Math.max(0, (to - p) / fade));
                if (from === 0 && p < fade) o = 1;   // the first caption shows at once
                cap.style.opacity = o;
                cap.classList.toggle('on', o > 0.5);
            });
        }
        showCaptions(0);
    }

    // ───────────── top bar: phone menu ─────────────
    function setUpNav() {
        var links = document.getElementById('navLinks');
        var burger = document.getElementById('navBurger');
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

    // ───────────── blocks fade up as they come into view ─────────────
    function setUpReveal() {
        if (!('IntersectionObserver' in window)) return;
        var watcher = new IntersectionObserver(function (entries) {
            entries.forEach(function (en) {
                if (en.isIntersecting) {
                    en.target.classList.add('in');
                    watcher.unobserve(en.target);
                }
            });
        }, { threshold: 0.12 });
        document.querySelectorAll('[data-up]').forEach(function (el) {
            el.classList.add('reveal');
            watcher.observe(el);
        });
    }

    // ───────────── the demo form: sent without leaving the page ─────────────
    // Saved by SiteController.Enquiry; the Super Admin sees it under Website Enquiries.
    function setUpEnquiryForm() {
        var form = document.getElementById('enqForm');
        var btn = document.getElementById('enqBtn');
        var msg = document.getElementById('enqMsg');

        function show(text, ok) {
            msg.textContent = text;
            msg.className = 'enq-msg ' + (ok ? 'ok' : 'err');
        }

        form.addEventListener('submit', function (e) {
            e.preventDefault();

            // the three required fields, checked here so the visitor gets a clear message
            var bad = null;
            ['Name', 'School', 'Phone'].forEach(function (n) {
                var input = form.elements[n];
                var empty = input.value.trim() === '';
                var phoneWrong = n === 'Phone' && !empty && input.value.replace(/\D/g, '').slice(-10).length < 10;
                input.classList.toggle('bad', empty || phoneWrong);
                if ((empty || phoneWrong) && !bad) bad = input;
            });
            if (bad) {
                show(bad.name === 'Phone' && bad.value.trim() !== '' ? 'Please enter a 10-digit mobile number.' : 'Please fill in your name, school name and mobile number.', false);
                bad.focus();
                return;
            }

            btn.disabled = true;
            show('Sending…', true);
            fetch(form.action, { method: 'POST', body: new FormData(form) })
                .then(function (r) {
                    if (r.status === 429) return { success: false, message: 'Too many tries. Please wait a few minutes or call us.' };
                    return r.json();
                })
                .then(function (d) {
                    show(d.message || (d.success ? 'Thank you.' : 'Could not send. Please call us.'), d.success);
                    if (d.success) form.reset();
                })
                .catch(function () { show('Could not send. Please check your internet or call us.', false); })
                .then(function () { btn.disabled = false; });
        });
    }
})();
