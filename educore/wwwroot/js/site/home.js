// Public website (Views/Site): the phone menu, a fade-in as blocks come into view, and the
// demo form. No libraries; everything on the page works without this file.
(function () {
    var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    setUpNav();
    setUpEnquiryForm();
    if (!reduceMotion) {
        setUpReveal();   // no motion: the CSS already shows everything
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
