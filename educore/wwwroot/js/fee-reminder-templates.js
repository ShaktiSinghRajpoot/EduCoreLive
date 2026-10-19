/* =========================================================================
   Fee reminder messages, shared by the pages that send them (Month-wise Dues).
   Tags filled per child on the server when sent: {student_name} {class}
   {due_amount} {days} {school_name}.

     EcFeeReminder.build('hi', 'firm')   -> the message text
     EcFeeReminder.LANG_NAME.hi          -> 'हिन्दी'
========================================================================= */
var EcFeeReminder = (function () {
    'use strict';

    var T = {
        en: {
            polite: 'Dear Parent, gentle reminder: the fee of ₹{due_amount} for {student_name} ({class}) is still pending. Kindly clear it at your convenience. Thank you! – {school_name}',
            firm: 'Dear Parent, the fee of ₹{due_amount} for {student_name} ({class}) is overdue by {days} days. Please pay immediately to avoid late charges. – {school_name}',
            final: 'FINAL NOTICE: The fee of ₹{due_amount} for {student_name} ({class}) is overdue by {days} days. Immediate payment is required. – {school_name}'
        },
        hi: {
            polite: 'प्रिय अभिभावक, सादर सूचना: {student_name} ({class}) की ₹{due_amount} फीस अभी बाकी है। कृपया सुविधानुसार जमा करें। धन्यवाद! – {school_name}',
            firm: 'प्रिय अभिभावक, {student_name} ({class}) की ₹{due_amount} फीस {days} दिनों से बकाया है। कृपया विलंब शुल्क से बचने हेतु शीघ्र भुगतान करें। – {school_name}',
            final: 'अंतिम सूचना: {student_name} ({class}) की ₹{due_amount} फीस {days} दिनों से बकाया है। कृपया तुरंत भुगतान करें। – {school_name}'
        },
        mr: { polite: 'प्रिय पालक, नम्र स्मरण: {student_name} ({class}) यांची ₹{due_amount} फी अद्याप बाकी आहे. कृपया सोयीनुसार भरावी. धन्यवाद! – {school_name}' },
        gu: { polite: 'પ્રિય વાલી, નમ્ર યાદ: {student_name} ({class}) ની ₹{due_amount} ફી હજુ બાકી છે. કૃપા કરી અનુકૂળતાએ ભરો. આભાર! – {school_name}' },
        bn: { polite: 'প্রিয় অভিভাবক, বিনীত স্মরণ: {student_name} ({class})-এর ₹{due_amount} ফি এখনও বাকি আছে। অনুগ্রহ করে সুবিধামতো পরিশোধ করুন। ধন্যবাদ! – {school_name}' },
        pa: { polite: 'ਪਿਆਰੇ ਮਾਪੇ, ਨਿਮਰ ਯਾਦ: {student_name} ({class}) ਦੀ ₹{due_amount} ਫੀਸ ਅਜੇ ਬਾਕੀ ਹੈ। ਕਿਰਪਾ ਕਰਕੇ ਸਹੂਲਤ ਅਨੁਸਾਰ ਜਮ੍ਹਾਂ ਕਰੋ। ਧੰਨਵਾਦ! – {school_name}' },
        ta: { polite: 'அன்புள்ள பெற்றோரே, அன்பான நினைவூட்டல்: {student_name} ({class}) இன் ₹{due_amount} கட்டணம் இன்னும் நிலுவையில் உள்ளது. தயவுசெய்து வசதியான நேரத்தில் செலுத்தவும். நன்றி! – {school_name}' },
        te: { polite: 'ప్రియమైన తల్లిదండ్రులారా, మృదువైన గుర్తుచేయుట: {student_name} ({class}) యొక్క ₹{due_amount} ఫీజు ఇంకా బాకీ ఉంది. దయచేసి అనుకూల సమయంలో చెల్లించండి. ధన్యవాదాలు! – {school_name}' }
    };

    var LANG_NAME = { en: 'English', hi: 'हिन्दी', enhi: 'EN + हिन्दी', mr: 'मराठी', gu: 'ગુજરાતી', bn: 'বাংলা', pa: 'ਪੰਜਾਬੀ', ta: 'தமிழ்', te: 'తెలుగు' };

    // English + Hindi together is the two messages one after the other.
    function build(lang, tone) {
        if (lang === 'enhi') return T.en[tone] + '\n\n' + (T.hi[tone] || T.hi.polite);
        var l = T[lang] || T.en;
        return l[tone] || l.polite || T.en[tone];
    }

    return { build: build, LANG_NAME: LANG_NAME };
})();
