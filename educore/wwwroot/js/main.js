/**
 * Main
 */

'use strict';

// Treat tablets (incl. iPad landscape at 1024px) as large screens so the
// left sidebar is the fixed, full-height pinned menu — not the slide-in
// drawer. Must match the CSS breakpoint in css/educore-theme.css
// (@media 768px–1199.98px). helpers.js loads before this file and reads
// this value via `this.LAYOUT_BREAKPOINT`, so overriding it here is enough.
if (window.Helpers) {
  window.Helpers.LAYOUT_BREAKPOINT = 768;
}

let menu, animate;
document.addEventListener('DOMContentLoaded', function () {
  // class for ios specific styles
  if (navigator.userAgent.match(/iPhone|iPad|iPod/i)) {
    document.body.classList.add('ios');
  }
});

(function () {
  // Initialize menu
  //-----------------

  let layoutMenuEl = document.querySelectorAll('#layout-menu');
  layoutMenuEl.forEach(function (element) {
    menu = new Menu(element, {
      orientation: 'vertical',
      closeChildren: false
    });
    // Change parameter to true if you want scroll animation
    window.Helpers.scrollToActive((animate = false));
    window.Helpers.mainMenu = menu;
  });

  // Initialize menu togglers and bind click on each
  let menuToggler = document.querySelectorAll('.layout-menu-toggle');
  menuToggler.forEach(item => {
    item.addEventListener('click', event => {
      event.preventDefault();
      window.Helpers.toggleCollapsed();
    });
  });

  // Tablet pop-in/out sidebar (768–1199.98px).
  // In this band the sidebar is pinned by CSS (educore-theme.css), and the
  // free template's Helpers.toggleCollapsed() is a no-op on "large" screens —
  // so wire the navbar hamburger to slide the pinned sidebar in/out and
  // reclaim the content space, remembering the choice across page loads.
  // Phones (<768px) and desktop (>=1200px) are untouched.
  (function () {
    const tablet = window.matchMedia('(min-width: 768px) and (max-width: 1199.98px)');
    const html = document.documentElement;
    const KEY = 'ec-tablet-menu-hidden';

    // Hidden by default on tablets: start collapsed unless the user explicitly
    // opened it before ('0'). Applied without animating on load.
    try {
      if (tablet.matches && localStorage.getItem(KEY) !== '0') {
        html.classList.add('ec-no-anim', 'ec-menu-hidden');
        requestAnimationFrame(() => requestAnimationFrame(() => html.classList.remove('ec-no-anim')));
      }
    } catch (e) {}

    // The chevron in the menu header (.layout-menu-toggle) collapses the sidebar.
    document.querySelectorAll('.layout-menu-toggle').forEach(toggle => {
      toggle.addEventListener('click', () => {
        if (!tablet.matches) return; // only act in the tablet band
        const hidden = html.classList.toggle('ec-menu-hidden');
        try { localStorage.setItem(KEY, hidden ? '1' : '0'); } catch (e) {}
      });
    });

    // A floating chevron handle brings the sidebar back once it's hidden
    // (the in-menu chevron slides away with the menu).
    const reopen = document.createElement('button');
    reopen.type = 'button';
    reopen.className = 'ec-menu-reopen';
    reopen.setAttribute('aria-label', 'Show menu');
    reopen.innerHTML = '<i class="icon-base bx bx-chevron-right"></i>';
    reopen.addEventListener('click', () => {
      html.classList.remove('ec-menu-hidden');
      try { localStorage.setItem(KEY, '0'); } catch (e) {}
    });
    document.body.appendChild(reopen);

    // Leaving the tablet band (rotate/resize) clears the override so desktop
    // and phone layouts behave normally.
    const onChange = () => { if (!tablet.matches) html.classList.remove('ec-menu-hidden'); };
    if (tablet.addEventListener) tablet.addEventListener('change', onChange);
    else if (tablet.addListener) tablet.addListener(onChange);
  })();

  // Display menu toggle (layout-menu-toggle) on hover with delay
  let delay = function (elem, callback) {
    let timeout = null;
    elem.onmouseenter = function () {
      // Set timeout to be a timer which will invoke callback after 300ms (not for small screen)
      if (!Helpers.isSmallScreen()) {
        timeout = setTimeout(callback, 300);
      } else {
        timeout = setTimeout(callback, 0);
      }
    };

    elem.onmouseleave = function () {
      // Clear any timers set to timeout
      document.querySelector('.layout-menu-toggle').classList.remove('d-block');
      clearTimeout(timeout);
    };
  };
  if (document.getElementById('layout-menu')) {
    delay(document.getElementById('layout-menu'), function () {
      // not for small screen
      if (!Helpers.isSmallScreen()) {
        document.querySelector('.layout-menu-toggle').classList.add('d-block');
      }
    });
  }

  // Display in main menu when menu scrolls
  let menuInnerContainer = document.getElementsByClassName('menu-inner'),
    menuInnerShadow = document.getElementsByClassName('menu-inner-shadow')[0];
  if (menuInnerContainer.length > 0 && menuInnerShadow) {
    menuInnerContainer[0].addEventListener('ps-scroll-y', function () {
      if (this.querySelector('.ps__thumb-y').offsetTop) {
        menuInnerShadow.style.display = 'block';
      } else {
        menuInnerShadow.style.display = 'none';
      }
    });
  }

  // Init helpers & misc
  // --------------------

  // Init BS Tooltip
  const tooltipTriggerList = [].slice.call(document.querySelectorAll('[data-bs-toggle="tooltip"]'));
  tooltipTriggerList.map(function (tooltipTriggerEl) {
    return new bootstrap.Tooltip(tooltipTriggerEl);
  });

  // Accordion active class
  const accordionActiveFunction = function (e) {
    if (e.type == 'show.bs.collapse' || e.type == 'show.bs.collapse') {
      e.target.closest('.accordion-item').classList.add('active');
    } else {
      e.target.closest('.accordion-item').classList.remove('active');
    }
  };

  const accordionTriggerList = [].slice.call(document.querySelectorAll('.accordion'));
  const accordionList = accordionTriggerList.map(function (accordionTriggerEl) {
    accordionTriggerEl.addEventListener('show.bs.collapse', accordionActiveFunction);
    accordionTriggerEl.addEventListener('hide.bs.collapse', accordionActiveFunction);
  });

  // Auto update layout based on screen size
  window.Helpers.setAutoUpdate(true);

  // Toggle Password Visibility
  window.Helpers.initPasswordToggle();

  // Speech To Text
  window.Helpers.initSpeechToText();

  // Manage menu expanded/collapsed with templateCustomizer & local storage
  //------------------------------------------------------------------

  // If current layout is horizontal OR current window screen is small (overlay menu) than return from here
  if (window.Helpers.isSmallScreen()) {
    return;
  }

  // If current layout is vertical and current window screen is > small

  // Auto update menu collapsed/expanded based on the themeConfig
  window.Helpers.setCollapsed(true, false);
})();
// Utils
function isMacOS() {
  return /Mac|iPod|iPhone|iPad/.test(navigator.userAgent);
}
