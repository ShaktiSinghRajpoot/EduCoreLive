/*
 * geo-cascade.js — Country → State → District cascading selects.
 *
 * Drop-in for ANY address form: render Views/Shared/_StateDistrictCity.cshtml and
 * this file wires itself up. No per-page JS.
 *
 * Contract: one container with [data-geo-cascade] holding elements marked
 *   [data-geo="country"|"state"|"district"|"city"]                <- visible inputs (ids)
 *   [data-geo-text="state"|"district"]                            <- hidden inputs (names)
 *
 * WHY the hidden text inputs: core.school_addresses (and the student/staff address
 * tables) still store state/district as varchar, and every proc, list filter and
 * report reads that text. So a save writes BOTH — the id for joins and integrity,
 * the text for everything that already exists. Drop the hidden inputs only after
 * those consumers move to the ids.
 */
(function () {
    'use strict';

    function opt(value, text) {
        var o = document.createElement('option');
        o.value = value;
        o.textContent = text;
        return o;
    }

    function fill(select, items, placeholder, selectedValue) {
        select.innerHTML = '';
        select.appendChild(opt('', placeholder));
        items.forEach(function (i) { select.appendChild(opt(i.value, i.text)); });
        if (selectedValue) select.value = selectedValue;
    }

    function selectedText(select) {
        var o = select.options[select.selectedIndex];
        return o && o.value ? o.textContent : '';
    }

    function get(url) {
        return fetch(url, { headers: { 'X-Requested-With': 'XMLHttpRequest' }, credentials: 'same-origin' })
            .then(function (r) { return r.ok ? r.json() : []; })
            .catch(function () { return []; });
    }

    function init(root) {
        if (root.dataset.geoReady === '1') return;
        root.dataset.geoReady = '1';

        var country = root.querySelector('[data-geo="country"]');
        var state = root.querySelector('[data-geo="state"]');
        var district = root.querySelector('[data-geo="district"]');
        var city = root.querySelector('[data-geo="city"]');
        var stateText = root.querySelector('[data-geo-text="state"]');
        var districtText = root.querySelector('[data-geo-text="district"]');
        var cityList = root.querySelector('datalist[data-geo-list="city"]');

        if (!state) return;

        function syncText() {
            if (stateText) stateText.value = selectedText(state);
            if (districtText) districtText.value = district ? selectedText(district) : '';
        }

        function loadDistricts(preselect) {
            if (!district) return Promise.resolve();
            if (!state.value) {
                fill(district, [], 'Select District');
                if (cityList) cityList.innerHTML = '';
                syncText();
                return Promise.resolve();
            }
            return get('/Geo/Districts?stateId=' + encodeURIComponent(state.value)).then(function (items) {
                fill(district, items, 'Select District', preselect);
                // The district names double as city suggestions — the district HQ is
                // the city for most schools, and it saves typing without forcing a
                // strict list (a school in an unlisted town can still be entered).
                if (cityList) {
                    cityList.innerHTML = '';
                    items.forEach(function (i) { cityList.appendChild(opt(i.text, '')); });
                }
                syncText();
            });
        }

        function loadStates(preselectState, preselectDistrict) {
            var url = '/Geo/States' + (country && country.value ? '?countryId=' + encodeURIComponent(country.value) : '');
            return get(url).then(function (items) {
                fill(state, items, 'Select State', preselectState);
                return loadDistricts(preselectDistrict);
            });
        }

        if (country) {
            country.addEventListener('change', function () { loadStates(); });
        }
        state.addEventListener('change', function () { loadDistricts(); });
        if (district) {
            district.addEventListener('change', function () {
                syncText();
                // Empty city + a district just picked = prefill the obvious answer.
                if (city && !city.value) city.value = selectedText(district);
            });
        }

        // Server-rendered selected values (edit forms) live in data-* on the root.
        var initialState = root.dataset.geoState || '';
        var initialDistrict = root.dataset.geoDistrict || '';

        if (state.options.length <= 1) {
            loadStates(initialState, initialDistrict);
        } else if (district && district.options.length <= 1 && state.value) {
            loadDistricts(initialDistrict);
        } else {
            syncText();
        }
    }

    function initAll() {
        document.querySelectorAll('[data-geo-cascade]').forEach(init);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initAll);
    } else {
        initAll();
    }

    // Exposed so a modal/AJAX-loaded form can wire up newly injected markup.
    window.ecGeoCascadeInit = initAll;
})();
