# ============================================================================
# Demo school data generator.
#
#   python -I make_demo_seed.py        (writes demo_school_seed.sql next to it)
#   psql -v ON_ERROR_STOP=1 --single-transaction -f demo_school_wipe.sql  (-v school=..)
#   psql -v ON_ERROR_STOP=1 --single-transaction -f demo_school_seed.sql
#
# Builds one full session (2026-27, April to "today") for a demo school: classes,
# subjects, staff, timetable, fee structure, 20 students a class, transport, and
# then the history (fees, attendance, exams, payroll, store ...) in later parts.
#
# The data is plain lists below (people, classes, fees). Everything that a real
# screen would create through a stored procedure goes through that procedure,
# so ledgers, receipt numbers and counters come out exactly as in daily use.
# The same lists are the shape a real school's data would come in (see the
# Import page), so this file doubles as a worked example of an onboarding.
#
# Random but repeatable: the same seed always gives the same school.
# ============================================================================
import random, datetime as dt

R = random.Random(2026)

T, S = 32, 45                      # tenant, school
ADMIN, TEACHER_U, ACC_U, REC_U, CLERK_U = 62, 63, 64, 65, 66
YEAR = '2026-27'
SESSION_START = dt.date(2026, 4, 1)
# the day the demo is built: payments, attendance, homework and front office run up to it
TODAY = dt.date.today()

SCHOOL = dict(
    name="Angel's Paradise School", code_prefix='APS',
    address1='Plot No. 1, Main Road, Street No. 1', address2='Village Wazirabad',
    city='Delhi', district='North Delhi', district_id=735, state='Delhi', state_id=32, pincode='110084',
    phone='8851837492', alt_phone='9711003832', email='schoolangelsparadise@gmail.com',
    contact='Principal', established=2008, board_id=1,
    reg_no='DoE/NW/2008/1147', affiliation='Recognised by Directorate of Education, Delhi',
)


def q(v):
    """SQL literal."""
    if v is None:
        return 'NULL'
    if isinstance(v, bool):
        return 'TRUE' if v else 'FALSE'
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (dt.date, dt.datetime)):
        return "'" + v.isoformat() + "'"
    return "'" + str(v).replace("'", "''") + "'"


def rows(values):
    return ',\n'.join('(' + ', '.join(q(x) for x in r) + ')' for r in values)


out = []
emit = out.append

# ── classes, subjects, fees ──────────────────────────────────────────────────
CLASSES = ['Nursery', 'LKG', 'UKG'] + ['Class %d' % i for i in range(1, 9)]
PRE = CLASSES[:3]
PRIMARY = ['Class %d' % i for i in range(1, 6)]
MIDDLE = ['Class 6', 'Class 7', 'Class 8']

SUBJECTS_OF = {}
for c in PRE:
    SUBJECTS_OF[c] = ['English', 'Hindi', 'Mathematics', 'EVS', 'Art & Craft', 'Physical Education']
for c in PRIMARY:
    SUBJECTS_OF[c] = ['English', 'Hindi', 'Mathematics', 'EVS', 'Computer', 'General Knowledge', 'Art & Craft', 'Physical Education']
for c in MIDDLE:
    SUBJECTS_OF[c] = ['English', 'Hindi', 'Mathematics', 'Science', 'Social Science', 'Sanskrit', 'Computer', 'Art & Craft', 'Physical Education']
ALL_SUBJECTS = ['English', 'Hindi', 'Mathematics', 'EVS', 'Science', 'Social Science', 'Sanskrit', 'Computer',
                'General Knowledge', 'Art & Craft', 'Physical Education']

# periods a week (8 class periods x 6 days = 48)
WEEKLY = {}
for c in PRE:
    WEEKLY[c] = {'English': 10, 'Hindi': 9, 'Mathematics': 10, 'EVS': 8, 'Art & Craft': 5, 'Physical Education': 6}
for c in PRIMARY:
    WEEKLY[c] = {'English': 9, 'Hindi': 8, 'Mathematics': 9, 'EVS': 7, 'Computer': 4, 'General Knowledge': 4,
                 'Art & Craft': 3, 'Physical Education': 4}
for c in MIDDLE:
    WEEKLY[c] = {'English': 8, 'Hindi': 7, 'Mathematics': 8, 'Science': 7, 'Social Science': 7, 'Sanskrit': 4,
                 'Computer': 3, 'Art & Craft': 2, 'Physical Education': 2}

TUITION = {'Nursery': 1800, 'LKG': 1800, 'UKG': 1800, 'Class 1': 2100, 'Class 2': 2100, 'Class 3': 2200,
           'Class 4': 2200, 'Class 5': 2300, 'Class 6': 2500, 'Class 7': 2600, 'Class 8': 2700}
ANNUAL = {c: (4500 if c in PRE else 5000 if c in PRIMARY else 5500) for c in CLASSES}
EXAMFEE = {c: (0 if c in PRE else 600 if c in PRIMARY else 750) for c in CLASSES}
COMPUTER = {c: (0 if c in PRE else 300) for c in CLASSES}
ADMISSION_FEE = {c: (5000 if c in PRE else 6000) for c in CLASSES}
# name, frequency, default amount, type, group, collection point, refundable
FEE_HEADS = [
    ('Registration Fee', 'One Time', 500, 'Mandatory', 'Academic', 'Registration', False),
    ('Admission Fee', 'One Time', 5000, 'Mandatory', 'Academic', 'Admission', False),
    ('Caution Money', 'One Time', 2000, 'Mandatory', 'Academic', 'Admission', True),
    ('Tuition Fee', 'Monthly', 2000, 'Mandatory', 'Academic', 'Recurring', False),
    ('Annual Charges', 'Yearly', 5000, 'Mandatory', 'Academic', 'Recurring', False),
    ('Exam Fee', 'Half Yearly', 600, 'Mandatory', 'Academic', 'Recurring', False),
    ('Computer Fee', 'Monthly', 300, 'Mandatory', 'Academic', 'Recurring', False),
    ('Transport Fee', 'Monthly', 1000, 'Optional', 'Transport', 'Recurring', False),
    ('Late Fine', 'One Time', 100, 'Optional', 'Fine / Penalty', 'Recurring', False),
]


def fee_lines(c):
    """(head, frequency, amount) of a class's structure."""
    lines = [('Admission Fee', 'One Time', ADMISSION_FEE[c]), ('Caution Money', 'One Time', 2000),
             ('Tuition Fee', 'Monthly', TUITION[c]), ('Annual Charges', 'Yearly', ANNUAL[c])]
    if EXAMFEE[c]:
        lines.append(('Exam Fee', 'Half Yearly', EXAMFEE[c]))
    if COMPUTER[c]:
        lines.append(('Computer Fee', 'Monthly', COMPUTER[c]))
    return lines


# ── people ───────────────────────────────────────────────────────────────────
BOYS = ('Aarav Vivaan Aditya Arjun Reyansh Ayaan Krishna Ishaan Shaurya Atharv Kabir Vihaan Rudra Dev Yash Harsh '
        'Kunal Rohan Aryan Lakshya Pranav Anirudh Samarth Dhruv Kartik Ansh Parth Ritvik Tanish Rishabh Mohit Nikhil '
        'Sahil Varun Aman Raghav Gaurav Abhay Shivam Tushar Ankit Mayank Sumit Rahul Faizan Arham Zaid Imran Gurpreet '
        'Harjot Jayesh Manav Naman Om Prince Rajat Sarthak Tejas Utkarsh Vedant Yuvraj').split()
GIRLS = ('Aadhya Ananya Diya Saanvi Myra Pari Kavya Ira Anika Navya Riya Siya Aarohi Ishita Khushi Mahi Nandini Pihu '
         'Prisha Radhika Sakshi Tanvi Vanshika Aditi Bhavya Charvi Disha Garima Harshita Jiya Kriti Lavanya Mansi '
         'Nisha Palak Rashi Shreya Simran Tanya Unnati Vaishnavi Yashika Zoya Alisha Ayesha Mehak Sana Gurleen Jasleen '
         'Anushka Divya Muskan Neha Poonam Sneha Tara Vidhi Shruti Payal').split()
SURNAMES = ('Sharma Verma Gupta Singh Yadav Kumar Chauhan Rawat Negi Bisht Jha Mishra Pandey Thakur Saini Khan '
            'Ansari Malik Tomar Rana Kashyap Prajapati Bansal Aggarwal Jain Arora Kapoor Mehra Bhatt Joshi Tiwari '
            'Dubey Kushwaha Paswan Rathore Bhardwaj Goel Sethi Chaudhary Solanki').split()
MUSLIM = {'Khan', 'Ansari', 'Malik'}
SIKH_FIRST = {'Gurpreet', 'Harjot', 'Gurleen', 'Jasleen'}
FATHERS = ('Rajesh Suresh Mahesh Ramesh Dinesh Sanjay Ajay Vijay Manoj Anil Sunil Pawan Rakesh Mukesh Naresh Satish '
           'Pradeep Sandeep Amit Sumit Vikas Deepak Rohit Ashok Pankaj Rajeev Sachin Vinod Arun Alok Neeraj Tarun').split()
FATHERS_M = 'Salim Irfan Javed Shahid Nadeem Arif Rizwan Asif'.split()
MOTHERS = ('Sunita Anita Kavita Rekha Pooja Neha Seema Priya Manju Geeta Meena Ritu Sarita Jyoti Renu Asha Nisha '
           'Kiran Sushma Poonam Mamta Shalini Archana Rachna Sangeeta Vandana').split()
MOTHERS_M = 'Shabana Rubina Nazia Farzana Shaheen Afreen'.split()
AREAS = [('Wazirabad Village', '110084'), ('Jagatpur Extension', '110084'), ('Sant Nagar, Burari', '110084'),
         ('Kamalpur, Burari', '110084'), ('Jharoda Majra', '110084'), ('Gopalpur Village', '110009'),
         ('Mukherjee Nagar', '110009'), ('Timarpur', '110054'), ('Nathupura', '110084'), ('Mukundpur', '110042'),
         ('Bhalswa Dairy', '110042'), ('Wazirabad Extension', '110084'), ('Majnu Ka Tilla', '110054'),
         ('Kaushik Enclave, Burari', '110084'), ('Swaroop Nagar', '110042')]
OCCUPATIONS = ['Business', 'Shopkeeper', 'Private Job', 'Government Job', 'Driver', 'Teacher', 'Contractor',
               'Electrician', 'Self Employed', 'Police', 'Bank Employee', 'Accountant', 'Tailor', 'Transporter']

used_phones = set()


def phone():
    # 90000xxxxx: looks real, reaches nobody (demo school, WhatsApp off).
    while True:
        p = '90000' + '%05d' % R.randint(10000, 99999)
        if p not in used_phones:
            used_phones.add(p)
            return p


# ── staff ────────────────────────────────────────────────────────────────────
# code, name, gender, designation, department, type, salary, qualification, joined, subjects, user
STAFF = []


def staff(name, gender, desig, dept, stype, salary, qual, joined, subjects=(), user=None, dob=None):
    code = 'APS-EMP-%03d' % (len(STAFF) + 1)
    STAFF.append(dict(code=code, name=name, gender=gender, desig=desig, dept=dept, type=stype, salary=salary,
                      qual=qual, joined=joined, subjects=list(subjects), user=user,
                      dob=dob or dt.date(R.randint(1972, 1998), R.randint(1, 12), R.randint(1, 28)),
                      mobile=phone()))
    return name


PRINCIPAL = staff('Neelam Sharma', 'Female', 'Principal', 'Administration', 'Teaching', 52000, 'M.A., B.Ed.', dt.date(2008, 4, 1))
# pre-primary and primary: the class teacher takes most of her own class
CT = {}
CT['Nursery'] = staff('Pooja Arora', 'Female', 'PRT', 'Academic', 'Teaching', 16000, 'NTT, B.A.', dt.date(2017, 7, 1))
CT['LKG'] = staff('Shikha Bansal', 'Female', 'PRT', 'Academic', 'Teaching', 16000, 'NTT, B.Com.', dt.date(2019, 4, 1))
CT['UKG'] = staff('Rachna Jain', 'Female', 'PRT', 'Academic', 'Teaching', 17000, 'NTT, B.A.', dt.date(2015, 4, 1))
CT['Class 1'] = staff('Sunita Rawat', 'Female', 'PRT', 'Academic', 'Teaching', 19000, 'B.A., B.Ed.', dt.date(2012, 4, 1))
CT['Class 2'] = staff('Kavita Negi', 'Female', 'PRT', 'Academic', 'Teaching', 19000, 'B.Sc., B.Ed.', dt.date(2014, 7, 1))
CT['Class 3'] = staff('Rekha Tiwari', 'Female', 'PRT', 'Academic', 'Teaching', 20000, 'M.A., B.Ed.', dt.date(2011, 4, 1))
CT['Class 4'] = staff('Priyanka Joshi', 'Female', 'PRT', 'Academic', 'Teaching', 18000, 'B.A., D.El.Ed.', dt.date(2020, 4, 1))
CT['Class 5'] = staff('Manju Chauhan', 'Female', 'PRT', 'Academic', 'Teaching', 21000, 'M.Sc., B.Ed.', dt.date(2010, 4, 1), user=TEACHER_U)
ENG = staff('Amit Kumar Shukla', 'Male', 'TGT', 'Academic', 'Teaching', 28000, 'M.A. (English), B.Ed.', dt.date(2013, 4, 1), ['English'])
HIN = staff('Sangeeta Dubey', 'Female', 'TGT', 'Academic', 'Teaching', 27000, 'M.A. (Hindi), B.Ed.', dt.date(2012, 7, 1), ['Hindi'])
MAT = staff('Vinod Kumar Yadav', 'Male', 'TGT', 'Academic', 'Teaching', 29000, 'M.Sc. (Maths), B.Ed.', dt.date(2011, 4, 1), ['Mathematics'])
SCI = staff('Deepak Verma', 'Male', 'TGT', 'Academic', 'Teaching', 28000, 'M.Sc. (Physics), B.Ed.', dt.date(2014, 4, 1), ['Science'])
SST = staff('Manoj Kumar Rai', 'Male', 'TGT', 'Academic', 'Teaching', 27000, 'M.A. (History), B.Ed.', dt.date(2016, 4, 1), ['Social Science'])
SAN = staff('Shiv Shankar Pandey', 'Male', 'TGT', 'Academic', 'Teaching', 24000, 'Shastri, M.A. (Sanskrit)', dt.date(2018, 4, 1), ['Sanskrit'])
COMP = staff('Rahul Jaiswal', 'Male', 'Computer Teacher', 'Academic', 'Teaching', 22000, 'MCA', dt.date(2019, 7, 1), ['Computer'])
ART = staff('Meera Prajapati', 'Female', 'Art Teacher', 'Academic', 'Teaching', 18000, 'BFA', dt.date(2018, 7, 1), ['Art & Craft'])
PE1 = staff('Sunil Kumar Yadav', 'Male', 'PET', 'Sports', 'Teaching', 21000, 'B.P.Ed.', dt.date(2013, 7, 1), ['Physical Education'])
PE2 = staff('Kiran Bisht', 'Female', 'PET', 'Sports', 'Teaching', 18000, 'B.P.Ed.', dt.date(2021, 4, 1), ['Physical Education'])
CT['Class 6'] = ENG
CT['Class 7'] = HIN
CT['Class 8'] = SCI
staff('Santosh Kumar Gupta', 'Male', 'Accountant', 'Accounts', 'Non-Teaching', 24000, 'B.Com., Tally', dt.date(2012, 4, 1), user=ACC_U)
staff('Dinesh Prasad', 'Male', 'Clerk', 'Administration', 'Non-Teaching', 16000, 'B.A.', dt.date(2015, 4, 1), user=CLERK_U)
staff('Komal Sharma', 'Female', 'Receptionist', 'Administration', 'Non-Teaching', 14000, 'B.A.', dt.date(2022, 4, 1), user=REC_U)
staff('Usha Tiwari', 'Female', 'Librarian', 'Academic', 'Non-Teaching', 16000, 'B.Lib.', dt.date(2016, 7, 1))
staff('Ram Lakhan', 'Male', 'Peon', 'Support', 'Support', 11000, '8th Pass', dt.date(2010, 4, 1))
staff('Shyam Babu', 'Male', 'Peon', 'Support', 'Support', 10500, '10th Pass', dt.date(2018, 4, 1))
staff('Phoolmati Devi', 'Female', 'Ayah', 'Support', 'Support', 10000, '5th Pass', dt.date(2014, 4, 1))
staff('Sita Devi', 'Female', 'Ayah', 'Support', 'Support', 10000, '8th Pass', dt.date(2019, 4, 1))
staff('Shiv Pujan Yadav', 'Male', 'Security Guard', 'Support', 'Support', 12000, '10th Pass', dt.date(2017, 4, 1))
DRV = [staff('Jitendra Yadav', 'Male', 'Driver', 'Transport', 'Transport', 15000, '10th Pass, HMV Licence', dt.date(2015, 4, 1)),
       staff('Ramashray Nishad', 'Male', 'Driver', 'Transport', 'Transport', 15000, '8th Pass, HMV Licence', dt.date(2017, 4, 1)),
       staff('Mohd. Salim', 'Male', 'Driver', 'Transport', 'Transport', 14500, '10th Pass, HMV Licence', dt.date(2020, 4, 1))]

DESIGNATIONS = [  # name, type, default department
    ('Principal', 'Teaching', 'Administration'), ('PRT', 'Teaching', 'Academic'), ('TGT', 'Teaching', 'Academic'),
    ('Computer Teacher', 'Teaching', 'Academic'), ('Art Teacher', 'Teaching', 'Academic'), ('PET', 'Teaching', 'Sports'),
    ('Accountant', 'Non-Teaching', 'Accounts'), ('Clerk', 'Non-Teaching', 'Administration'),
    ('Receptionist', 'Non-Teaching', 'Administration'), ('Librarian', 'Non-Teaching', 'Academic'),
    ('Peon', 'Support', 'Support'), ('Ayah', 'Support', 'Support'), ('Security Guard', 'Support', 'Support'),
    ('Driver', 'Transport', 'Transport')]
DEPARTMENTS = ['Academic', 'Administration', 'Accounts', 'Sports', 'Support', 'Transport']

# ── timetable (no teacher in two rooms at once) ──────────────────────────────
CLASS_PERIOD_SEQ = [2, 3, 4, 6, 7, 9, 10, 11]   # see PERIODS below
DAYS = [1, 2, 3, 4, 5, 6]                      # Mon .. Sat


def teacher_for(c, subj):
    if c in PRE:
        if subj == 'Art & Craft':
            return ART
        if subj == 'Physical Education':
            return PE2
        return CT[c]
    if c in PRIMARY:
        if subj == 'Computer':
            return COMP
        if subj == 'Art & Craft':
            return ART
        if subj == 'Physical Education':
            return PE1 if c in ('Class 1', 'Class 2', 'Class 3') else PE2
        return CT[c]
    return {'English': ENG, 'Hindi': HIN, 'Mathematics': MAT, 'Science': SCI, 'Social Science': SST,
            'Sanskrit': SAN, 'Computer': COMP, 'Art & Craft': ART, 'Physical Education': PE1}[subj]


def build_timetable():
    """One class at a time; a class that gets stuck is tried again with another order."""
    busy = set()          # (teacher, day, seq)
    grid = {}             # (class, day, seq) -> (subject, teacher)
    slots = [(d, p) for d in DAYS for p in CLASS_PERIOD_SEQ]
    for c in CLASSES:
        for attempt in range(500):
            left = dict(WEEKLY[c])
            mine = {}
            order = slots[:]
            R.shuffle(order)
            ok = True
            for d, p in order:
                free = [sb for sb, n in left.items() if n > 0
                        and (teacher_for(c, sb), d, p) not in busy
                        and sum(1 for pp in CLASS_PERIOD_SEQ if mine.get((d, pp)) == sb) < 2]
                if not free:
                    ok = False
                    break
                top = max(left[sb] for sb in free)
                sb = R.choice([x for x in free if left[x] == top])
                mine[(d, p)] = sb
                left[sb] -= 1
                busy.add((teacher_for(c, sb), d, p))
            if ok:
                for (d, p), sb in mine.items():
                    grid[(c, d, p)] = (sb, teacher_for(c, sb))
                break
            for (d, p), sb in mine.items():          # undo this attempt
                busy.discard((teacher_for(c, sb), d, p))
        else:
            raise SystemExit('timetable: no clash-free week for ' + c)
    return grid


GRID = build_timetable()

# ── students ─────────────────────────────────────────────────────────────────
AGE0 = {'Nursery': 3, 'LKG': 4, 'UKG': 5}
for i in range(1, 9):
    AGE0['Class %d' % i] = 5 + i

STUDENTS = []
adm_seq = {}


def adm_no(year):
    adm_seq[year] = adm_seq.get(year, 0) + 1
    return 'APS/%d/%03d' % (year, adm_seq[year])


for ci, c in enumerate(CLASSES):
    names = set()
    kids = []
    for k in range(20):
        girl = R.random() < 0.47
        community = R.choices(['hindu', 'muslim', 'sikh'], [86, 9, 5])[0]
        while True:
            if community == 'muslim':
                first = R.choice(['Ayesha', 'Zoya', 'Sana', 'Alisha', 'Mehak', 'Inaya'] if girl else ['Faizan', 'Arham', 'Zaid', 'Imran', 'Ayaan', 'Rehan'])
                sur = R.choice(['Khan', 'Ansari', 'Malik', 'Qureshi'])
            elif community == 'sikh':
                first = R.choice(['Gurleen', 'Jasleen', 'Simran', 'Harleen'] if girl else ['Gurpreet', 'Harjot', 'Jaskaran', 'Manveer'])
                sur = 'Kaur' if girl else 'Singh'
            else:
                first = R.choice([n for n in (GIRLS if girl else BOYS) if n not in SIKH_FIRST and n not in ('Ayesha', 'Zoya', 'Sana', 'Alisha', 'Mehak', 'Faizan', 'Arham', 'Zaid', 'Imran', 'Ayaan')])
                sur = R.choice([x for x in SURNAMES if x not in MUSLIM])
            nm = first + ' ' + sur
            if nm not in names:
                names.add(nm)
                break
        muslim = community == 'muslim'
        sikh = community == 'sikh'
        fsur = 'Singh' if sikh else sur
        father = (R.choice(FATHERS_M) if muslim else R.choice(FATHERS)) + ' ' + (R.choice(['Singh', 'Singh Bedi', 'Singh Gill']) if sikh else fsur)
        mother = (R.choice(MOTHERS_M) if muslim else R.choice(MOTHERS)) + ' ' + ('Kaur' if sikh else fsur)
        age = AGE0[c]
        dob = dt.date(2026 - age - 1, R.randint(4, 12), R.randint(1, 28)) if R.random() < 0.6 else dt.date(2026 - age, R.randint(1, 3), R.randint(1, 28))
        # who joined when: Nursery all new this April; others mostly old students
        r = R.random()
        if c == 'Nursery' or r < 0.12:
            joined = dt.date(2026, 4, R.randint(1, 10))
        elif r < 0.17 and c not in PRE:
            joined = dt.date(2026, R.choice([7, 8]), R.randint(1, 20))     # joined mid-session
        else:
            first_class = max(0, ci - R.choice([0, 1, 1, 2, 3, 4, 5, 6, ci]))
            joined = dt.date(2026 - (ci - first_class), 4, R.randint(1, 10))
            if joined.year == 2026:
                joined = dt.date(2025, 4, R.randint(1, 10))
        area, pin = R.choice(AREAS)
        house = R.choice(['H.No. %d' % R.randint(1, 450), 'House %d, Gali No. %d' % (R.randint(1, 300), R.randint(1, 12)),
                          'Plot %d, Block %s' % (R.randint(1, 200), R.choice('ABCDE'))])
        kids.append(dict(
            name=nm, gender='Female' if girl else 'Male', dob=dob, cls=c, section='A', joined=joined,
            adm=adm_no(joined.year), father=father, mother=mother, mobile=phone(),
            alt=phone() if R.random() < 0.4 else None,
            address='%s, %s, Delhi - %s' % (house, area, pin), area=area,
            blood=R.choice(['A+', 'B+', 'O+', 'AB+', 'B+', 'O+', 'A-', 'O-']),
            religion='Islam' if muslim else 'Sikh' if sikh else 'Hindu',
            category=R.choice(['General', 'General', 'OBC', 'OBC', 'SC', 'General']) if not muslim else R.choice(['General', 'OBC']),
            occupation=R.choice(OCCUPATIONS), mother_occ=R.choice(['Homemaker'] * 4 + ['Teacher', 'Private Job', 'Tailor', 'Beautician']),
            income=R.choice([180000, 240000, 300000, 360000, 450000, 600000, 720000, 900000]),
            aadhaar='%04d%04d%04d' % (R.randint(2000, 9999), R.randint(1000, 9999), R.randint(1000, 9999)),
            new=joined >= SESSION_START,
        ))
    kids.sort(key=lambda x: x['name'])
    for roll, k in enumerate(kids, 1):
        k['roll'] = roll
    STUDENTS.extend(kids)

# how each family pays, how regular each child is, how well they do in exams
for k in STUDENTS:
    r = R.random()
    k['payer'] = ('monthly' if r < 0.52 else 'quarterly' if r < 0.72 else 'late' if r < 0.88
                  else 'defaulter' if r < 0.97 else 'stopped')
    k['att'] = R.choice([0.97, 0.96, 0.95, 0.94, 0.93, 0.92, 0.9, 0.88, 0.85, 0.8])
    k['ability'] = min(0.97, max(0.35, R.gauss(0.68, 0.14)))
    k['gone_from'] = None
# two children stopped coming three weeks ago (the "may have left" warning)
for k in R.sample([x for x in STUDENTS if x['cls'] in ('Class 3', 'Class 6') and not x['new']], 2):
    k['gone_from'] = dt.date(2026, 9, 26)
    k['payer'] = 'stopped'

# transport: three routes, about a third of the children ride
ROUTES = [
    ('Route 1 - Burari', 'Burari, Sant Nagar, Kaushik Enclave',
     [('Sant Nagar Chowk', 1200), ('Kamalpur', 1100), ('Kaushik Enclave', 1300), ('Burari Crossing', 1200)],
     'DL1PC 4521', 40, DRV[0]),
    ('Route 2 - Mukherjee Nagar', 'Mukherjee Nagar, Gopalpur, Timarpur',
     [('Mukherjee Nagar', 1400), ('Gopalpur', 1100), ('Timarpur', 1300), ('Majnu Ka Tilla', 1400)],
     'DL1PB 7783', 32, DRV[1]),
    ('Route 3 - Jagatpur', 'Jagatpur, Jharoda Majra, Nathupura, Mukundpur',
     [('Jagatpur Extension', 900), ('Jharoda Majra', 1000), ('Nathupura', 1100), ('Mukundpur', 1300)],
     'DL1PD 1902', 26, DRV[2]),
]
AREA_STOP = {'Sant Nagar, Burari': (0, 0), 'Kamalpur, Burari': (0, 1), 'Kaushik Enclave, Burari': (0, 2),
             'Swaroop Nagar': (0, 3), 'Mukherjee Nagar': (1, 0), 'Gopalpur Village': (1, 1), 'Timarpur': (1, 2),
             'Majnu Ka Tilla': (1, 3), 'Jagatpur Extension': (2, 0), 'Jharoda Majra': (2, 1), 'Nathupura': (2, 2),
             'Mukundpur': (2, 3), 'Bhalswa Dairy': (2, 3)}
seats = [r[4] for r in ROUTES]
for k in STUDENTS:
    st = AREA_STOP.get(k['area'])
    if st and R.random() < 0.55 and seats[st[0]] > 0:
        k['stop'] = st
        seats[st[0]] -= 1
    else:
        k['stop'] = None

# ============================================================================
#  SQL
# ============================================================================
emit("""-- GENERATED by make_demo_seed.py -- do not edit by hand.
SET client_min_messages = warning;
SET statement_timeout = 0;
-- the history below is entered for past days; allowed for this run only
UPDATE core.school_settings SET attendance_backdate_days = 400 WHERE school_id = %(S)d;
""" % dict(S=S))

# ── school identity ──
s = SCHOOL
emit("""
-- ── 1. School identity (the school agreed to be the demo) ──
UPDATE core.schools SET school_name = {name}, display_name = {name}, updated_by = {A}, updated_at = now() WHERE school_id = {S};
UPDATE core.school_profiles SET registration_number = {reg}, affiliation_number = {aff}, board_id = {board},
       established_year = {est}, website = NULL, description = {desc},
       signature_url = NULL, seal_url = NULL, signatory_name = {prin}, signatory_designation = 'Principal',
       updated_by = {A}, updated_at = now()
 WHERE school_id = {S};
UPDATE core.school_addresses SET address_line1 = {a1}, address_line2 = {a2}, city = {city}, district = {dist},
       state = {state}, pincode = {pin}, state_id = {sid}, district_id = {did}, updated_by = {A}, updated_at = now()
 WHERE school_id = {S} AND is_primary;
UPDATE core.school_contacts SET contact_name = {prin}, designation = 'Principal', email = {email}, phone = {ph},
       alternate_phone = {alt}, updated_by = {A}, updated_at = now()
 WHERE school_id = {S} AND is_primary;
UPDATE core.school_settings SET enable_whatsapp = FALSE, receipt_format = 'A5' WHERE school_id = {S};
UPDATE core.school_messaging SET whatsapp_on = FALSE WHERE school_id = {S};
-- registration on, but a direct admission is allowed too
UPDATE core.school_admission_workflow_settings
   SET enable_registration = TRUE, registration_required_before_admission = FALSE, enable_registration_fee = TRUE,
       enable_security_fee = TRUE,
       collect_fee_at_admission = TRUE, updated_by = {A}, updated_at = now()
 WHERE school_id = {S};
""".format(name=q(s['name']), A=ADMIN, S=S, reg=q(s['reg_no']), aff=q(s['affiliation']), board=s['board_id'],
           est=s['established'], desc=q("One of the best schools in North Delhi. Nursery to Class 8, English medium."),
           prin=q('Neelam Sharma'), a1=q(s['address1']), a2=q(s['address2']), city=q(s['city']), dist=q(s['district']),
           state=q(s['state']), pin=q(s['pincode']), sid=s['state_id'], did=s['district_id'], email=q(s['email']),
           ph=q(s['phone']), alt=q(s['alt_phone'])))

# ── session, classes, sections, subjects ──
emit("""
-- ── 2. Session, classes, subjects ──
INSERT INTO academic.academic_years (tenant_id, school_id, academic_year_name, start_date, end_date, is_current, charge_fees_from, created_by)
VALUES ({T}, {S}, {Y}, '2026-04-01', '2027-03-31', TRUE, 'AdmissionMonth', {A});
INSERT INTO academic.academic_classes (tenant_id, school_id, academic_year_id, class_name, display_order, stream, created_by)
SELECT {T}, {S}, ay.academic_year_id, v.n, v.o, 'gen', {A}
  FROM (VALUES {cls}) v(n, o)
  JOIN academic.academic_years ay ON ay.school_id = {S} AND ay.academic_year_name = {Y};
INSERT INTO academic.school_subjects (tenant_id, school_id, subject_name, created_by)
SELECT {T}, {S}, v.n, {A} FROM (VALUES {subj}) v(n);
INSERT INTO academic.class_subjects (tenant_id, school_id, academic_year_id, academic_class_id, subject_id, display_order, created_by)
SELECT {T}, {S}, c.academic_year_id, c.academic_class_id, sb.subject_id, v.o, {A}
  FROM (VALUES {cs}) v(c, s, o)
  JOIN academic.academic_classes c ON c.school_id = {S} AND c.class_name = v.c
  JOIN academic.school_subjects sb ON sb.school_id = {S} AND sb.subject_name = v.s;
""".format(T=T, S=S, A=ADMIN, Y=q(YEAR), cls=rows([(c, i + 1) for i, c in enumerate(CLASSES)]),
           subj=rows([(x,) for x in ALL_SUBJECTS]),
           cs=rows([(c, sname, i + 1) for c in CLASSES for i, sname in enumerate(SUBJECTS_OF[c])])))

# ── periods, calendar, grade scale ──
PERIODS = [(1, 'assembly', 'Assembly', '07:50', '08:10'), (2, 'class', 'Period 1', '08:10', '08:50'),
           (3, 'class', 'Period 2', '08:50', '09:30'), (4, 'class', 'Period 3', '09:30', '10:10'),
           (5, 'break', 'Short Break', '10:10', '10:25'), (6, 'class', 'Period 4', '10:25', '11:05'),
           (7, 'class', 'Period 5', '11:05', '11:45'), (8, 'lunch', 'Lunch', '11:45', '12:15'),
           (9, 'class', 'Period 6', '12:15', '12:55'), (10, 'class', 'Period 7', '12:55', '13:35'),
           (11, 'class', 'Period 8', '13:35', '14:15')]
HOLIDAYS = [('2026-04-03', 'Good Friday'), ('2026-04-14', 'Dr. Ambedkar Jayanti'), ('2026-05-01', 'Buddha Purnima'),
            ('2026-08-15', 'Independence Day'), ('2026-08-28', 'Raksha Bandhan'), ('2026-09-04', 'Janmashtami'),
            ('2026-10-02', 'Gandhi Jayanti'), ('2026-10-20', 'Dussehra'), ('2026-11-24', 'Guru Nanak Jayanti'),
            ('2026-12-25', 'Christmas'), ('2027-01-26', 'Republic Day'), ('2027-03-04', 'Holi')]
RANGES = [('2026-05-16', '2026-06-27', 'Summer Vacation'), ('2026-11-07', '2026-11-11', 'Diwali Break'),
          ('2027-01-01', '2027-01-10', 'Winter Vacation')]
cal = [(d, t) for d, t in HOLIDAYS]
for a, b, t in RANGES:
    d = dt.date.fromisoformat(a)
    while d <= dt.date.fromisoformat(b):
        cal.append((d.isoformat(), t))
        d += dt.timedelta(days=1)
GRADES = [('A1', 91, 100, 10, 'Outstanding'), ('A2', 81, 90.99, 9, 'Excellent'), ('B1', 71, 80.99, 8, 'Very Good'),
          ('B2', 61, 70.99, 7, 'Good'), ('C1', 51, 60.99, 6, 'Above Average'), ('C2', 41, 50.99, 5, 'Average'),
          ('D', 33, 40.99, 4, 'Pass'), ('E', 0, 32.99, None, 'Needs Improvement')]
emit("""
-- ── 3. Bell schedule, calendar, grade scale ──
INSERT INTO academic.period_structure (tenant_id, school_id, seq, period_type, label, start_time, end_time, created_by)
SELECT {T}, {S}, v.q, v.t, v.l, v.a::time, v.b::time, {A} FROM (VALUES {per}) v(q, t, l, a, b);
INSERT INTO academic.school_calendar_settings (tenant_id, school_id, weekly_off_days, updated_by)
VALUES ({T}, {S}, '{{0}}', {A});
INSERT INTO academic.school_calendar (tenant_id, school_id, calendar_date, day_type, title, created_by)
SELECT {T}, {S}, v.d::date, 'holiday', v.t, {A} FROM (VALUES {cal}) v(d, t)
 WHERE extract(dow FROM v.d::date) <> 0;
INSERT INTO academic.grade_scale (tenant_id, school_id, grade_label, min_percent, max_percent, grade_point, remark, display_order, created_by)
SELECT {T}, {S}, v.g, v.a, v.b, v.p, v.r, v.o, {A} FROM (VALUES {gr}) v(g, a, b, p, r, o);
""".format(T=T, S=S, A=ADMIN, per=rows(PERIODS), cal=rows(cal),
           gr=rows([g + (i + 1,) for i, g in enumerate(GRADES)])))

# ── staff ──
emit("""
-- ── 4. Departments, designations, staff ──
INSERT INTO config.departments (tenant_id, school_id, name, sort_order, created_by)
SELECT {T}, {S}, v.n, v.o, {A} FROM (VALUES {dep}) v(n, o);
INSERT INTO config.designations (tenant_id, school_id, name, staff_type, sort_order, default_department, created_by)
SELECT {T}, {S}, v.n, v.t, v.o, v.d, {A} FROM (VALUES {des}) v(n, t, o, d);
INSERT INTO core.staff (tenant_id, school_id, employee_code, full_name, gender, dob, mobile, email, address, staff_type,
                        department, designation, joining_date, qualification, experience_years, status, monthly_salary,
                        bank_account_no, ifsc_code, user_id, created_by)
SELECT {T}, {S}, v.c, v.n, v.g, v.dob::date, v.m, (SELECT email FROM core.users u WHERE u.user_id = v.u), v.addr, v.t,
       v.dep, v.des, v.j::date, v.qual, v.exp, 'Active', v.sal, v.acc, 'SBIN0001707', v.u, {A}
  FROM (VALUES {st}) v(c, n, g, dob, m, addr, t, dep, des, j, qual, exp, sal, acc, u);
-- the demo logins become these people
UPDATE core.user_profiles p SET full_name = s.full_name, phone = s.mobile, designation = s.designation,
       updated_by = {A}, updated_at = now()
  FROM core.staff s WHERE s.school_id = {S} AND s.user_id = p.user_id;
UPDATE core.user_profiles SET full_name = 'Neelam Sharma', designation = 'Principal', updated_at = now()
 WHERE user_id = {A};
""".format(T=T, S=S, A=ADMIN, dep=rows([(d, i + 1) for i, d in enumerate(DEPARTMENTS)]),
           des=rows([(n, t, i + 1, d) for i, (n, t, d) in enumerate(DESIGNATIONS)]),
           st=rows([(x['code'], x['name'], x['gender'], x['dob'].isoformat(), x['mobile'],
                     '%s, Delhi' % R.choice([a for a, _ in AREAS]), x['type'], x['dept'], x['desig'],
                     x['joined'].isoformat(), x['qual'], max(1, 2026 - x['joined'].year + R.randint(0, 6)),
                     x['salary'], '3%010d' % R.randint(10**9, 10**10 - 1), x['user']) for x in STAFF])))

# ── sections with class teachers, timetable ──
emit("""
-- ── 5. Sections + class teachers, timetable ──
INSERT INTO academic.academic_class_sections (tenant_id, school_id, academic_year_id, academic_class_id, section_name,
                                              display_order, capacity, room_no, class_teacher_staff_id, created_by)
SELECT {T}, {S}, c.academic_year_id, c.academic_class_id, 'A', 1, 30, v.r, st.staff_id, {A}
  FROM (VALUES {sec}) v(c, r, t)
  JOIN academic.academic_classes c ON c.school_id = {S} AND c.class_name = v.c
  JOIN core.staff st ON st.school_id = {S} AND st.full_name = v.t;
INSERT INTO academic.timetable (tenant_id, school_id, academic_year_id, academic_class_section_id, day_of_week, period_seq,
                                subject_id, staff_id, room_no, created_by)
SELECT {T}, {S}, sec.academic_year_id, sec.academic_class_section_id, v.d, v.p, sb.subject_id, st.staff_id, v.r, {A}
  FROM (VALUES {tt}) v(c, d, p, s, t, r)
  JOIN academic.academic_classes c ON c.school_id = {S} AND c.class_name = v.c
  JOIN academic.academic_class_sections sec ON sec.academic_class_id = c.academic_class_id
  JOIN academic.school_subjects sb ON sb.school_id = {S} AND sb.subject_name = v.s
  JOIN core.staff st ON st.school_id = {S} AND st.full_name = v.t;
""".format(T=T, S=S, A=ADMIN,
           sec=rows([(c, 'Room %d' % (i + 1), CT[c]) for i, c in enumerate(CLASSES)]),
           tt=rows([(c, d, p, sub, t, 'Computer Lab' if sub == 'Computer' else 'Ground' if sub == 'Physical Education'
                     else 'Activity Room' if sub == 'Art & Craft' else 'Room %d' % (CLASSES.index(c) + 1))
                    for (c, d, p), (sub, t) in sorted(GRID.items())])))

# ── fee heads + structures ──
emit("""
-- ── 6. Fee heads, fee structure of every class ──
INSERT INTO core.school_fee_heads (tenant_id, school_id, fee_head_name, frequency, default_amount, fee_type, fee_group,
                                   collection_point, is_refundable, created_by)
SELECT {T}, {S}, v.n, v.f, v.a, v.t, v.g, v.p, v.r, {A} FROM (VALUES {fh}) v(n, f, a, t, g, p, r);
INSERT INTO core.school_fee_structures (tenant_id, school_id, class_name, academic_year, one_time_total, monthly_total,
                                        yearly_total, half_yearly_total, quarterly_total, annual_total, created_by)
SELECT {T}, {S}, v.c, {Y}, v.ot, v.mo, v.yr, v.hy, 0, v.an, {A} FROM (VALUES {fs}) v(c, ot, mo, yr, hy, an);
INSERT INTO core.school_fee_structure_details (tenant_id, school_id, fee_structure_id, fee_head_id, fee_head_name, frequency,
                                               amount, is_selected, created_by)
SELECT {T}, {S}, fs.fee_structure_id, fh.fee_head_id, fh.fee_head_name, fh.frequency, v.a, TRUE, {A}
  FROM (VALUES {fd}) v(c, h, a)
  JOIN core.school_fee_structures fs ON fs.school_id = {S} AND fs.class_name = v.c AND fs.academic_year = {Y}
  JOIN core.school_fee_heads fh ON fh.school_id = {S} AND fh.fee_head_name = v.h;
INSERT INTO core.fee_dues_settings (tenant_id, school_id, late_fee_amount, late_fee_grace_days, hold_after_months, updated_by)
VALUES ({T}, {S}, 100, 10, 3, {A});
""".format(T=T, S=S, A=ADMIN, Y=q(YEAR), fh=rows(FEE_HEADS),
           fs=rows([(c,
                     sum(a for h, f, a in fee_lines(c) if f == 'One Time'),
                     sum(a for h, f, a in fee_lines(c) if f == 'Monthly'),
                     sum(a for h, f, a in fee_lines(c) if f == 'Yearly'),
                     sum(a for h, f, a in fee_lines(c) if f == 'Half Yearly'),
                     sum(a * (12 if f == 'Monthly' else 2 if f == 'Half Yearly' else 1) for h, f, a in fee_lines(c)))
                    for c in CLASSES]),
           fd=rows([(c, h, a) for c in CLASSES for h, f, a in fee_lines(c)])))

# ── transport routes + buses ──
emit("""-- ── 7. Transport: routes with stops, buses with drivers ──
DO $$
DECLARE r refcursor; v_route int; v_drv int; v_ph text; BEGIN""")
for name, desc, stops, bus, cap, drv in ROUTES:
    stops_json = '[' + ','.join('{"stopId":0,"stopName":%s,"monthlyFare":%d,"displayOrder":%d}' %
                                ('"' + n + '"', f, i + 1) for i, (n, f) in enumerate(stops)) + ']'
    emit("""  CALL core.sp_transport_route_manage('SaveRoute', {T}, {S}, {A}, NULL, {n}, {d}, {j}::jsonb, r); CLOSE r;
  SELECT route_id INTO v_route FROM core.transport_routes WHERE school_id = {S} AND route_name = {n};
  SELECT staff_id, mobile INTO v_drv, v_ph FROM core.staff WHERE school_id = {S} AND full_name = {dn};
  CALL core.sp_transport_vehicle_manage('SaveVehicle', {T}, {S}, {A}, NULL, {v}, {c}, {dn}, v_ph, v_route, v_drv, r); CLOSE r;""".format(
        T=T, S=S, A=ADMIN, n=q(name), d=q(desc), j=q(stops_json), v=q(bus), c=cap, dn=q(drv)))
emit("END $$;")

# ── students (through the admission procedure) ──
emit("""
-- ── 8. Students: 20 a class, admitted through core.sp_admission_manage ──
CREATE TEMP TABLE d_students (adm text, roll int, name text, gender text, dob date, cls text, section text, joined date,
    father text, mother text, mobile text, alt text, address text, blood text, religion text, category text,
    occupation text, mother_occ text, income numeric, aadhaar text, is_new boolean, stop_route text, stop_name text,
    payer text, att numeric, ability numeric, gone_from date);
INSERT INTO d_students VALUES
{rows};
""".format(rows=rows([(k['adm'], k['roll'], k['name'], k['gender'], k['dob'].isoformat(), k['cls'], k['section'],
                       k['joined'].isoformat(), k['father'], k['mother'], k['mobile'], k['alt'], k['address'], k['blood'],
                       k['religion'], k['category'], k['occupation'], k['mother_occ'], k['income'], k['aadhaar'], k['new'],
                       ROUTES[k['stop'][0]][0] if k['stop'] else None,
                       ROUTES[k['stop'][0]][2][k['stop'][1]][0] if k['stop'] else None,
                       k['payer'], k['att'], round(k['ability'], 3), k['gone_from'].isoformat() if k['gone_from'] else None)
                      for k in STUDENTS])))
emit("""
DO $$
DECLARE
    d record; r refcursor; v_res record; v_plan jsonb; v_docs jsonb;
BEGIN
    FOR d IN SELECT * FROM d_students ORDER BY joined, adm LOOP
        -- the class's fee structure; Admission Fee and Caution Money only for a child admitted this session
        SELECT jsonb_agg(jsonb_build_object('feeHeadId', fd.fee_head_id, 'feeHeadName', fd.fee_head_name,
                                            'frequency', fd.frequency, 'amount', fd.amount, 'isOptional', FALSE))
          INTO v_plan
          FROM core.school_fee_structure_details fd
          JOIN core.school_fee_structures fs ON fs.fee_structure_id = fd.fee_structure_id
         WHERE fs.school_id = {S} AND fs.class_name = d.cls AND fs.academic_year = {Y}
           AND (d.is_new OR fd.frequency <> 'One Time');
        v_docs := '[{{"name":"Birth Certificate","status":"Collected"}},{{"name":"Aadhaar Card","status":"Collected"}},{{"name":"Passport Photos","status":"Collected"}},{{"name":"Transfer Certificate","status":"Pending"}}]'::jsonb;
        CALL core.sp_admission_manage(
            p_operation => 'SaveAdmission', p_tenant_id => {T}, p_school_id => {S}, p_action_user_id => {A},
            p_admission_no => d.adm, p_roll_no => d.roll::text, p_student_name => d.name, p_gender => d.gender,
            p_dob => d.dob, p_class_name => d.cls, p_section => d.section, p_academic_year => {Y},
            p_admission_date => GREATEST(d.joined, DATE '2026-04-01'),
            p_guardian_name => d.father, p_mother_name => d.mother, p_mobile => d.mobile, p_alt_mobile => d.alt,
            p_address => d.address, p_blood_group => d.blood, p_religion => d.religion, p_category => d.category,
            p_nationality => 'Indian', p_mother_tongue => CASE WHEN d.religion = 'Sikh' THEN 'Punjabi' WHEN d.religion = 'Islam' THEN 'Urdu' ELSE 'Hindi' END,
            p_id_proof_no => d.aadhaar, p_father_occupation => d.occupation, p_mother_occupation => d.mother_occ,
            p_annual_income => d.income, p_documents => v_docs, p_fee_plan_json => v_plan,
            p_result => r);
        FETCH r INTO v_res; CLOSE r;
        IF COALESCE(v_res.success, 0) = 0 THEN
            RAISE EXCEPTION 'Admission of % failed: %', d.name, v_res.message;
        END IF;
        -- an old student's real admission date (the procedure bills from the session start)
        IF d.joined < DATE '2026-04-01' THEN
            UPDATE core.students SET admission_date = d.joined WHERE student_id = v_res.student_id;
        END IF;
    END LOOP;
END $$;
""".format(T=T, S=S, A=ADMIN, Y=q(YEAR)))

# ── transport assignments (bus fee lines) ──
emit("""
-- ── 9. Bus riders ──
DO $$
DECLARE d record; r refcursor; v_res record;
BEGIN
    FOR d IN SELECT st.student_id, ds.joined, rt.route_id, sp.stop_id
               FROM d_students ds
               JOIN core.students st ON st.school_id = {S} AND st.admission_no = ds.adm
               JOIN core.transport_routes rt ON rt.school_id = {S} AND rt.route_name = ds.stop_route
               JOIN core.transport_stops sp ON sp.route_id = rt.route_id AND sp.stop_name = ds.stop_name
              ORDER BY ds.adm LOOP
        CALL core.sp_transport_assign_manage('SaveAssignment', {T}, {S}, {A}, d.student_id, d.route_id, d.stop_id, {Y},
                                             GREATEST(d.joined, DATE '2026-04-01'), 12, r);
        CLOSE r;
    END LOOP;
END $$;
""".format(T=T, S=S, A=ADMIN, Y=q(YEAR)))

# ── store: suppliers, items, purchases, books & uniform given to every child ──
SUPPLIERS = [  # name, contact, mobile, address, gstin
    ('Sharma Book Depot', 'Rakesh Sharma', '9000071210', 'Nai Sarak, Chandni Chowk, Delhi', '07AAKFS4821K1Z3'),
    ('Kapoor Uniforms', 'Vikas Kapoor', '9000071322', 'Gandhi Nagar Market, Delhi', '07ABPPK3311M1ZQ'),
    ('Delhi Stationery Mart', 'Anil Jain', '9000071458', 'Kamla Nagar, Delhi', '07AAGFD9035C1Z8'),
    ('Shree Ganesh Traders', 'Mohan Lal', '9000071599', 'Burari Main Road, Delhi', None),
]
BOOKSET = {'Nursery': 1450, 'LKG': 1650, 'UKG': 1850, 'Class 1': 2350, 'Class 2': 2450, 'Class 3': 2700,
           'Class 4': 2850, 'Class 5': 3050, 'Class 6': 3550, 'Class 7': 3750, 'Class 8': 3950}
SIZES = {'Nursery': '20', 'LKG': '22', 'UKG': '22', 'Class 1': '24', 'Class 2': '26', 'Class 3': '26',
         'Class 4': '28', 'Class 5': '30', 'Class 6': '32', 'Class 7': '34', 'Class 8': '36'}
# name, category, type, unit, cost, price, min stock, for classes (None = all), supplier, bought
ITEMS = []
for c in CLASSES:
    ITEMS.append(('Book Set - ' + c, 'Books', 'Saleable', 'Set', round(BOOKSET[c] * 0.8), BOOKSET[c], 3, [c], 0, 22))
for sz in ['20', '22', '24', '26', '28', '30', '32', '34', '36']:
    ITEMS.append(('Uniform Set - Size ' + sz, 'Uniform', 'Saleable', 'Set', 620, 950, 4, None, 1, 30))
for sz in ['22', '26', '30', '34', '38']:
    ITEMS.append(('Winter Sweater - Size ' + sz, 'Uniform', 'Saleable', 'Piece', 380, 590, 5, None, 1, 40))
ITEMS += [
    ('School Tie', 'Uniform', 'Saleable', 'Piece', 45, 80, 20, None, 1, 260),
    ('School Belt', 'Uniform', 'Saleable', 'Piece', 55, 90, 20, None, 1, 260),
    ('Sports T-Shirt (House)', 'Uniform', 'Saleable', 'Piece', 160, 250, 15, None, 1, 120),
    ('School Diary 2026-27', 'Stationery', 'Saleable', 'Piece', 70, 120, 10, None, 2, 250),
    ('Student ID Card', 'Stationery', 'Saleable', 'Piece', 35, 100, 10, None, 2, 250),
    ('Notebook Set (12)', 'Stationery', 'Saleable', 'Set', 300, 450, 15, None, 2, 200),
    ('School Bag', 'Accessories', 'Saleable', 'Piece', 420, 650, 6, None, 3, 60),
    ('Chalk Box (White)', 'Teaching Aids', 'Consumable', 'Box', 45, 0, 20, None, 2, 120),
    ('Whiteboard Marker', 'Teaching Aids', 'Consumable', 'Piece', 22, 0, 30, None, 2, 200),
    ('A4 Paper Ream', 'Office', 'Consumable', 'Ream', 280, 0, 10, None, 2, 40),
    ('Attendance Register', 'Office', 'Consumable', 'Piece', 90, 0, 5, None, 2, 15),
    ('Floor Cleaner (5 L)', 'Housekeeping', 'Consumable', 'Can', 380, 0, 4, None, 3, 12),
    ('Football', 'Sports', 'Reusable', 'Piece', 650, 0, 2, None, 3, 6),
    ('Cricket Kit', 'Sports', 'Reusable', 'Set', 3200, 0, 1, None, 3, 2),
    ('First Aid Kit', 'Health', 'Reusable', 'Piece', 850, 0, 2, None, 3, 4),
]
# what every child took in April (and what new children took when they joined)
for k in STUDENTS:
    kit = ['Book Set - ' + k['cls'], 'Uniform Set - Size ' + SIZES[k['cls']], 'School Tie', 'School Belt',
           'School Diary 2026-27', 'Student ID Card']
    if R.random() < 0.55:
        kit.append('Notebook Set (12)')
    if R.random() < 0.18:
        kit.append('School Bag')
    if k['cls'] not in PRE and R.random() < 0.5:
        kit.append('Sports T-Shirt (House)')
    if R.random() < 0.25:     # winter has begun: some bought the sweater this month
        kit.append('Winter Sweater - Size ' + str(min([22, 26, 30, 34, 38], key=lambda v: abs(v - int(SIZES[k['cls']])))))
    k['kit'] = kit

emit("""
-- ── 10. Store: suppliers, items, purchases ──
DO $$
DECLARE r refcursor; v_sup int; v_item int; v_loc int;
BEGIN""")
for name, person, mob, addr, gst in SUPPLIERS:
    emit("""  CALL core.sp_inventory_manage('SAVESUPPLIER', {T}, {S}, {A}, p_supplier_name => {n}, p_contact_person => {c},
       p_mobile => {m}, p_address => {a}, p_gstin => {g}, p_result => r); CLOSE r;""".format(
        T=T, S=S, A=ADMIN, n=q(name), c=q(person), m=q(mob), a=q(addr), g=q(gst)))
for (name, cat, typ, unit, cost, price, mn, forc, sup, qty) in ITEMS:
    emit("""  CALL core.sp_inventory_manage('SAVEITEM', {T}, {S}, {A}, p_item_name => {n}, p_category => {c}, p_item_type => {t},
       p_unit_type => {u}, p_opening_stock => 0, p_min_stock => {mn}, p_cost_price => {cost}, p_selling_price => {pr},
       p_is_active => TRUE, p_result => r); CLOSE r;""".format(
        T=T, S=S, A=ADMIN, n=q(name), c=q(cat), t=q(typ), u=q(unit), mn=mn, cost=cost, pr=price))
    if forc:
        emit("  UPDATE core.inventory_items SET for_class = ARRAY[{c}] WHERE school_id = {S} AND item_name = {n};".format(
            S=S, c=', '.join(q(x) for x in forc), n=q(name)))
emit("END $$;")

# purchases: one bill per supplier in March (what the children will take, plus a few
# spare), a top-up in July, and the winter stock in October
demand = {}
for k in STUDENTS:
    for it in k['kit']:
        demand[it] = demand.get(it, 0) + 1
LOW = {'Uniform Set - Size 30', 'School Bag', 'Book Set - Class 6'}       # left running low on purpose


def march_qty(it):
    name, typ = it[0], it[2]
    if 'Sweater' in name:
        return 0
    if typ != 'Saleable':
        return it[9]
    return demand.get(name, 0) + (1 if name in LOW else R.randint(4, 12))


PURCHASES = []   # (supplier idx, date, invoice, mode, [(item, qty)])
for si in range(len(SUPPLIERS)):
    lines = [(it[0], march_qty(it)) for it in ITEMS if it[8] == si and march_qty(it) > 0]
    PURCHASES.append((si, '2026-03-24', 'INV/%d/%03d' % (si + 1, 1201 + si * 7), 'Bank Transfer' if si < 2 else 'Cash', lines))
PURCHASES.append((1, '2026-07-02', 'KU/2026/0441', 'Credit', [('Uniform Set - Size 24', 6), ('Uniform Set - Size 30', 6), ('School Tie', 30), ('School Belt', 30)]))
PURCHASES.append((0, '2026-07-06', 'SBD/26-27/118', 'Bank Transfer', [('Book Set - Class 3', 3), ('Book Set - Class 7', 3), ('Book Set - Class 4', 2)]))
PURCHASES.append((1, '2026-10-05', 'KU/2026/0612', 'Credit',
                  [(it[0], demand.get(it[0], 0) + R.randint(8, 15)) for it in ITEMS if 'Sweater' in it[0]]))
PURCHASES.append((2, '2026-10-09', 'DSM/9932', 'Cash', [('Chalk Box (White)', 60), ('Whiteboard Marker', 100), ('A4 Paper Ream', 20)]))
emit("""
DO $$
DECLARE r refcursor; r2 refcursor; v_items jsonb; v_sup int;
BEGIN""")
for si, d, inv, mode, lines in PURCHASES:
    emit("""  SELECT supplier_id INTO v_sup FROM core.inventory_suppliers WHERE school_id = {S} AND supplier_name = {sup};
  SELECT jsonb_agg(jsonb_build_object('itemId', i.item_id, 'quantity', v.q, 'unitPrice', i.cost_price, 'taxPercent', 0))
    INTO v_items FROM (VALUES {vals}) v(n, q) JOIN core.inventory_items i ON i.school_id = {S} AND i.item_name = v.n;
  CALL core.sp_inventory_purchase_manage('SAVE', {T}, {S}, {A},
       p_supplier_id => v_sup,
       p_purchase_date => {d}, p_invoice_no => {inv}, p_payment_mode => {mode}, p_remarks => NULL, p_items => v_items,
       p_result => r, p_result2 => r2); CLOSE r; CLOSE r2;""".format(
        T=T, S=S, A=ADMIN, vals=rows(lines), sup=q(SUPPLIERS[si][0]), d=q(d), inv=q(inv), mode=q(mode)))
emit("END $$;")

# books & uniform given to the children (each line becomes a fee line on the child)
emit("""
-- ── 11. Books & uniform given to every child (a fee line each) ──
CREATE TEMP TABLE d_kit (adm text, item text, on_date date);
INSERT INTO d_kit VALUES
{kit};
DO $$
DECLARE d record; r refcursor; v_items jsonb; v_res record;
BEGIN
    FOR d IN SELECT k.adm, k.on_date, st.student_id, st.class_name
               FROM (SELECT DISTINCT adm, on_date FROM d_kit) k
               JOIN core.students st ON st.school_id = {S} AND st.admission_no = k.adm
              ORDER BY k.on_date, k.adm LOOP
        SELECT jsonb_agg(jsonb_build_object('itemId', i.item_id, 'qty', 1)) INTO v_items
          FROM d_kit x JOIN core.inventory_items i ON i.school_id = {S} AND i.item_name = x.item
         WHERE x.adm = d.adm AND x.on_date = d.on_date;
        CALL core.sp_inventory_student_sale('Sell', {T}, {S}, {A}, d.student_id, {Y}, d.class_name, NULL, v_items, p_result => r);
        CLOSE r;
        -- the sale is dated the day it happened (the procedure writes "today")
        UPDATE core.inventory_stock_ledger SET movement_date = d.on_date::text
         WHERE school_id = {S} AND movement_type <> 'Purchase' AND movement_date = CURRENT_DATE::text
           AND reference_id IN (SELECT sale_id FROM core.inventory_student_sales
                                 WHERE student_id = d.student_id AND sale_date = CURRENT_DATE);
        UPDATE core.inventory_student_sales SET sale_date = d.on_date, created_at = d.on_date + time '10:30'
         WHERE student_id = d.student_id AND sale_date = CURRENT_DATE;
        UPDATE core.student_ledger SET due_date = d.on_date::text
         WHERE student_id = d.student_id AND fee_head_id IS NULL AND due_date = CURRENT_DATE::text;
    END LOOP;
END $$;
""".format(T=T, S=S, A=ADMIN, Y=q(YEAR),
           kit=rows([(k['adm'], it,
                      (max(k['joined'], dt.date(2026, 4, 2)) if 'Sweater' not in it else dt.date(2026, 10, R.randint(6, 17))).isoformat())
                     for k in STUDENTS for it in k['kit']])))

# ── fees: how each family pays, from April to today ──
emit("""
-- ── 12. Fee collections, April to today, through core.sp_fee_payment_collect ──
DO $$
DECLARE
    d record; r refcursor; v_items jsonb; v_res record; v_day date; v_m int; v_user int; v_mode text; v_ref text;
    v_cnt int := 0;
BEGIN
    FOR d IN SELECT st.student_id, ds.payer, ds.joined, ds.gone_from, ds.adm
               FROM d_students ds JOIN core.students st ON st.school_id = {S} AND st.admission_no = ds.adm
              ORDER BY ds.adm LOOP
        FOR v_m IN 4..__TODAY_MONTH__ LOOP
            -- the day this family pays in month v_m (NULL = they do not pay this month)
            -- most families pay in the first ten days, some later in the month
            v_day := make_date(2026, v_m, CASE WHEN abs(hashtext(d.adm || 'w' || v_m)) % 10 < 7
                                               THEN 1 + abs(hashtext(d.adm || v_m)) % 10
                                               ELSE 11 + abs(hashtext(d.adm || v_m)) % 17 END);
            IF d.payer = 'quarterly' AND v_m NOT IN (4, 7, 10) THEN v_day := NULL; END IF;
            IF d.payer = 'late' AND v_m NOT IN (4, 6, 8) THEN v_day := NULL; END IF;
            IF d.payer = 'defaulter' AND v_m NOT IN (4, 6) THEN v_day := NULL; END IF;
            IF d.payer = 'stopped' AND v_m > 8 THEN v_day := NULL; END IF;
            IF v_day IS NOT NULL AND v_m IN (5, 6) THEN v_day := make_date(2026, v_m, 5 + abs(hashtext(d.adm)) % 10); END IF;
            IF v_day IS NULL OR v_day > DATE __TODAY__ OR v_day < GREATEST(d.joined, DATE '2026-04-01') THEN CONTINUE; END IF;
            IF extract(dow FROM v_day) = 0 THEN v_day := v_day + 1; END IF;

            SELECT jsonb_agg(jsonb_build_object('ledgerId', l.ledger_id,
                       'amount', l.amount_due - l.amount_paid - COALESCE(l.concession, 0), 'concession', 0))
              INTO v_items
              FROM core.student_ledger l
             WHERE l.student_id = d.student_id AND l.due_date::date <= v_day
               AND l.amount_due - l.amount_paid - COALESCE(l.concession, 0) > 0
               AND COALESCE(l.status, '') NOT IN ('Closed', 'Cancelled');
            IF v_items IS NULL THEN CONTINUE; END IF;

            v_user := CASE abs(hashtext(d.adm || 'u' || v_m)) % 10 WHEN 0 THEN {A} WHEN 1 THEN {REC} ELSE {ACC} END;
            v_mode := CASE abs(hashtext(d.adm || 'm' || v_m)) % 20 WHEN 0 THEN 'Cheque' WHEN 1 THEN 'Bank Transfer'
                                                                   WHEN 2 THEN 'Card' ELSE
                      CASE WHEN abs(hashtext(d.adm || 'x' || v_m)) % 10 < 4 THEN 'UPI' ELSE 'Cash' END END;
            v_ref  := CASE v_mode WHEN 'Cheque' THEN (100000 + abs(hashtext(d.adm || v_m)) % 899999)::text
                                  WHEN 'UPI' THEN 'UPI' || (600000000 + abs(hashtext(d.adm || 'r' || v_m)) % 399999999)::text
                                  WHEN 'Bank Transfer' THEN 'NEFT' || (10000000 + abs(hashtext(d.adm || 'n' || v_m)) % 89999999)::text
                                  ELSE NULL END;
            CALL core.sp_fee_payment_collect(
                p_tenant_id => {T}, p_school_id => {S}, p_action_user_id => v_user, p_student_id => d.student_id,
                p_items => v_items, p_extras => '[]'::jsonb, p_payment_mode => v_mode, p_reference_no => v_ref,
                p_payment_date => v_day, p_result => r);
            CLOSE r;
            v_cnt := v_cnt + 1;
        END LOOP;
    END LOOP;
    -- the receipts were written "now"; they belong to the day they were taken
    UPDATE core.fee_payments SET created_at = payment_date::date + time '09:30' + (payment_id % 360) * interval '1 minute'
     WHERE school_id = {S} AND created_at::date = CURRENT_DATE AND payment_date::date < CURRENT_DATE;
    RAISE NOTICE 'fee receipts: %', v_cnt;
END $$;
""".format(T=T, S=S, A=ADMIN, ACC=ACC_U, REC=REC_U))

# ── student attendance: every school day ──
emit("""
-- ── 13. Student attendance, every school day April to today ──
DO $$
DECLARE
    v_day date; c record; r refcursor; v_items jsonb; v_n int := 0; v_user int;
BEGIN
    FOR v_day IN SELECT g::date FROM generate_series(DATE '2026-04-01', DATE __TODAY__, interval '1 day') g LOOP
        CONTINUE WHEN academic.fn_school_day_type({T}, {S}, v_day) IN ('holiday', 'weekly_off');
        FOR c IN SELECT DISTINCT cls FROM d_students LOOP
            -- today's register is still open in two classes
            CONTINUE WHEN v_day = DATE __TODAY__ AND c.cls IN ('Class 2', 'Class 7');
            SELECT jsonb_agg(jsonb_build_object('studentId', st.student_id, 'status',
                     CASE WHEN ds.gone_from IS NOT NULL AND v_day >= ds.gone_from THEN 'Absent'
                          WHEN (abs(hashtext(ds.adm || v_day::text)) % 1000) / 1000.0 >= ds.att THEN
                               CASE WHEN abs(hashtext(ds.adm || 'l' || v_day::text)) % 6 = 0 THEN 'Leave' ELSE 'Absent' END
                          WHEN abs(hashtext(ds.adm || 't' || v_day::text)) % 40 = 0 THEN 'Late'
                          ELSE 'Present' END,
                     'remarks', NULL))
              INTO v_items
              FROM d_students ds JOIN core.students st ON st.school_id = {S} AND st.admission_no = ds.adm
             WHERE ds.cls = c.cls AND ds.joined <= v_day;
            CONTINUE WHEN v_items IS NULL;
            -- the class teacher marks it; one without a login of her own uses the office login
            SELECT s.user_id INTO v_user FROM core.staff s
              JOIN academic.academic_class_sections sec ON sec.class_teacher_staff_id = s.staff_id
              JOIN academic.academic_classes ac ON ac.academic_class_id = sec.academic_class_id
             WHERE ac.school_id = {S} AND ac.class_name = c.cls;
            CALL core.sp_attendance_save({T}, {S}, COALESCE(v_user, {A}), v_day, c.cls, 'A', v_items, r);
            CLOSE r;
            v_n := v_n + 1;
        END LOOP;
    END LOOP;
    RAISE NOTICE 'registers saved: %', v_n;
END $$;
""".format(T=T, S=S, A=ADMIN))

# ── staff leave, staff attendance, salary ──
LEAVES = [  # staff, type, from, to, reason, decision
    ('Kavita Negi', 'Casual', '2026-04-24', '2026-04-24', 'Family function', 'Approved'),
    ('Deepak Verma', 'Sick', '2026-07-14', '2026-07-16', 'Viral fever', 'Approved'),
    ('Shikha Bansal', 'Casual', '2026-08-10', '2026-08-11', 'Sister\'s wedding', 'Approved'),
    ('Ram Lakhan', 'Casual', '2026-08-21', '2026-08-21', 'Personal work', 'Approved'),
    ('Manoj Kumar Rai', 'Earned', '2026-09-07', '2026-09-09', 'Going to native village (Ballia)', 'Approved'),
    ('Rekha Tiwari', 'Sick', '2026-09-23', '2026-09-24', 'Dental treatment', 'Approved'),
    ('Komal Sharma', 'Casual', '2026-10-05', '2026-10-05', 'Bank work', 'Approved'),
    ('Rahul Jaiswal', 'Casual', '2026-10-09', '2026-10-09', 'Personal work', 'Rejected'),
    ('Sunita Rawat', 'Casual', '2026-10-21', '2026-10-22', 'Durga Puja at home', None),
    ('Mohd. Salim', 'Casual', '2026-10-23', '2026-10-23', 'Child unwell', None),
]
emit("""
-- ── 14. Staff leave (applied, then approved / rejected) ──
DO $$
DECLARE r refcursor; v_res record; v_staff int; v_id int;
BEGIN""")
for name, typ, a, b, why, dec in LEAVES:
    emit("""  SELECT staff_id INTO v_staff FROM core.staff WHERE school_id = {S} AND full_name = {n};
  CALL core.sp_staff_leave_manage('APPLY', {T}, {S}, {A}, NULL, v_staff, {t}, {a}::date, {b}::date, {w}, NULL, NULL, r); CLOSE r;
  SELECT max(leave_id) INTO v_id FROM core.staff_leave WHERE school_id = {S} AND staff_id = v_staff;
  UPDATE core.staff_leave SET applied_at = {a}::date - 3 + time '09:00' WHERE leave_id = v_id;""".format(
        T=T, S=S, A=ADMIN, n=q(name), t=q(typ), a=q(a), b=q(b), w=q(why)))
    if dec:
        emit("""  CALL core.sp_staff_leave_manage('DECIDE', {T}, {S}, {A}, v_id, NULL, NULL, NULL, NULL, NULL, {d}, {rm}, r); CLOSE r;
  UPDATE core.staff_leave SET decided_at = applied_at + interval '1 day 2 hours' WHERE leave_id = v_id;""".format(
            T=T, S=S, A=ADMIN, d=q(dec), rm=q('Approved by Principal' if dec == 'Approved' else 'Exam week, please plan after 20th')))
emit("END $$;")

emit("""
-- ── 15. Staff attendance, every school day ──
DO $$
DECLARE v_day date; r refcursor; r2 refcursor; v_ids int[]; v_st text[]; v_rm text[];
BEGIN
    FOR v_day IN SELECT g::date FROM generate_series(DATE '2026-04-01', DATE __TODAY__, interval '1 day') g LOOP
        CONTINUE WHEN academic.fn_school_day_type({T}, {S}, v_day) IN ('holiday', 'weekly_off');
        SELECT array_agg(s.staff_id ORDER BY s.staff_id),
               array_agg(CASE
                   WHEN EXISTS (SELECT 1 FROM core.staff_leave l WHERE l.staff_id = s.staff_id AND l.status = 'Approved'
                                 AND v_day BETWEEN l.from_date::date AND l.to_date::date) THEN 'Leave'
                   WHEN abs(hashtext(s.employee_code || v_day::text)) % 100 < 2 THEN 'Absent'
                   WHEN abs(hashtext(s.employee_code || 'h' || v_day::text)) % 100 < 2 THEN 'HalfDay'
                   WHEN abs(hashtext(s.employee_code || 'l' || v_day::text)) % 100 < 5 THEN 'Late'
                   ELSE 'Present' END ORDER BY s.staff_id),
               array_agg(NULL::text ORDER BY s.staff_id)
          INTO v_ids, v_st, v_rm
          FROM core.staff s WHERE s.school_id = {S} AND s.is_active;
        CALL core.sp_staff_attendance_manage('Save', {T}, {S}, {A}, v_day, NULL, v_ids, v_st, v_rm, r, r2);
        CLOSE r; CLOSE r2;
    END LOOP;
END $$;

-- ── 16. Salary: April to September paid, October not run yet ──
DO $$
DECLARE v_m int; r refcursor; v_slip record;
BEGIN
    FOR v_m IN 4..9 LOOP
        CALL core.sp_staff_payroll_manage('RUN', {T}, {S}, {A}, v_m, 2026, NULL, NULL, r); CLOSE r;
        FOR v_slip IN SELECT payroll_id FROM core.staff_payroll WHERE school_id = {S} AND pay_month = v_m AND pay_year = 2026 LOOP
            CALL core.sp_staff_payroll_manage('MARK_PAID', {T}, {S}, {ACC}, NULL, NULL, v_slip.payroll_id, NULL, r,
                                              'Bank Transfer', 'SAL-' || 2026 || lpad(v_m::text, 2, '0') || '-' || v_slip.payroll_id);
            CLOSE r;
        END LOOP;
    END LOOP;
END $$;
""".format(T=T, S=S, A=ADMIN, ACC=ACC_U))

# ── exams, marks, results ──
EXAM_SUBJ = {c: [x for x in SUBJECTS_OF[c] if x not in ('Physical Education', 'Art & Craft')] for c in CLASSES}
EXAMS = [  # name, type, start, end, max, pass, marks entered?
    ('Unit Test 1', 'unit1', dt.date(2026, 7, 13), dt.date(2026, 7, 18), 20, 7, True),
    ('Half Yearly Examination', 'half', dt.date(2026, 9, 21), dt.date(2026, 9, 30), 80, 27, True),
    ('Unit Test 2', 'unit2', dt.date(2026, 11, 16), dt.date(2026, 11, 21), 20, 7, False),
]



def exam_days(start, end):
    days, d = [], start
    while d <= end:
        if d.weekday() != 6 and d.isoformat() not in dict(HOLIDAYS):
            days.append(d)
        d += dt.timedelta(days=1)
    return days


EXAM_ROWS = []   # exam, class, subject, date, start, end, max, pass
for name, typ, a, b, mx, ps, done in EXAMS:
    days = exam_days(a, b)
    for c in CLASSES:
        if c in PRE and mx <= 20:
            continue                       # no unit tests in pre-primary
        for i, sb in enumerate(EXAM_SUBJ[c]):
            # more papers than days: the second paper of a day comes after a break
            second = i >= len(days)
            st, et = (('11:00', '12:30') if second else ('09:00', '10:30')) if mx <= 20 else                      (('12:30', '15:30') if second else ('09:00', '12:00'))
            EXAM_ROWS.append((name, c, sb, days[i % len(days)].isoformat(), st, et, mx, ps))

emit("""
-- ── 17. Exams: two done (marks entered, results published), one coming ──
CREATE TEMP TABLE d_exam_subjects (exam text, cls text, subj text, d date, st time, et time, mx numeric, ps numeric);
INSERT INTO d_exam_subjects VALUES
{rows};
DO $$
DECLARE r refcursor; r2 refcursor; r3 refcursor; r4 refcursor; v_year int; v_items text; v_exam int; e record; m record; v_marks text;
BEGIN
    SELECT academic_year_id INTO v_year FROM academic.academic_years WHERE school_id = {S} AND academic_year_name = {Y};
    FOR e IN SELECT * FROM (VALUES {exams}) v(n, t, a, b, done) LOOP
        SELECT jsonb_agg(jsonb_build_object('classId', x.cid, 'sections', '[]'::jsonb, 'subjects', x.subs))::text INTO v_items
          FROM (SELECT c.academic_class_id cid,
                       jsonb_agg(jsonb_build_object('subjectId', sb.subject_id, 'examDate', ds.d::text,
                                 'startTime', to_char(ds.st, 'HH24:MI'), 'endTime', to_char(ds.et, 'HH24:MI'),
                                 'maxMarks', ds.mx, 'passMarks', ds.ps) ORDER BY ds.d) subs
                  FROM d_exam_subjects ds
                  JOIN academic.academic_classes c ON c.school_id = {S} AND c.class_name = ds.cls
                  JOIN academic.school_subjects sb ON sb.school_id = {S} AND sb.subject_name = ds.subj
                 WHERE ds.exam = e.n GROUP BY c.academic_class_id) x;
        CALL academic.sp_school_admin_exam_manage('SaveExam', {T}, {S}, {A}, v_year, NULL, NULL, e.n, e.t, e.a::date, e.b::date,
                                                  NULL, v_items, r, r2);
        CLOSE r; CLOSE r2;
        SELECT exam_id INTO v_exam FROM academic.exams WHERE school_id = {S} AND exam_name = e.n AND NOT is_deleted;
        CALL academic.sp_school_admin_exam_manage('SetStatus', {T}, {S}, {A}, v_year, NULL, v_exam, NULL, NULL, NULL, NULL,
                                                  'Published', NULL, r, r2);
        CLOSE r; CLOSE r2;
        CONTINUE WHEN NOT e.done;
        -- marks: each child near their usual level, a few absent
        FOR m IN SELECT c.academic_class_id cid, sb.subject_id sid, ds.mx, ds.subj, ds.cls
                   FROM d_exam_subjects ds
                   JOIN academic.academic_classes c ON c.school_id = {S} AND c.class_name = ds.cls
                   JOIN academic.school_subjects sb ON sb.school_id = {S} AND sb.subject_name = ds.subj
                  WHERE ds.exam = e.n LOOP
            SELECT jsonb_agg(jsonb_build_object('studentId', st.student_id,
                       'marks', CASE WHEN abs(hashtext(st.admission_no || e.n || m.subj)) % 60 = 0 THEN NULL
                                     ELSE least(m.mx, greatest(0, round(m.mx * (dst.ability
                                          + ((abs(hashtext(st.admission_no || e.n || m.subj || 'n')) % 31) - 15) / 100.0)))) END,
                       'absent', abs(hashtext(st.admission_no || e.n || m.subj)) % 60 = 0))::text
              INTO v_marks
              FROM d_students dst JOIN core.students st ON st.school_id = {S} AND st.admission_no = dst.adm
             WHERE dst.cls = m.cls AND dst.joined <= e.b::date;
            CALL academic.sp_school_admin_exam_marks_manage('SaveMarks', {T}, {S}, {A}, v_exam, m.cid, m.sid, 'A', v_marks, TRUE, r, r2);
            CLOSE r; CLOSE r2;
        END LOOP;
        CALL academic.sp_school_admin_exam_results_manage('PublishResults', {T}, {S}, {A}, v_exam, NULL, NULL, NULL, r, r2, r3, r4);
        CLOSE r; CLOSE r2; CLOSE r3; CLOSE r4;
    END LOOP;
END $$;
""".format(T=T, S=S, A=ADMIN, Y=q(YEAR), rows=rows(EXAM_ROWS),
           exams=rows([(n, t, a.isoformat(), b.isoformat(), done) for n, t, a, b, mx, ps, done in EXAMS])))

# ── homework of the last two weeks ──
HW = {
    'English': ['Write 10 sentences on "My Favourite Festival"', 'Learn the spellings of Lesson %d',
                'Complete the worksheet on nouns and pronouns', 'Read Chapter %d and answer Q1-Q5'],
    'Hindi': ['"Mera Vidyalaya" par 10 vakya likhiye', 'Path %d ke kathin shabd yaad kijiye', 'Sulekh: ek page',
              'Path %d ke prashn-uttar likhiye'],
    'Mathematics': ['Exercise %d.2: Q1 to Q10', 'Learn tables 12 to 15', 'Solve the worksheet on fractions',
                    'Exercise %d.4 all questions'],
    'EVS': ['Draw and colour the parts of a plant', 'Collect 5 leaves and paste them in the notebook',
            'Lesson %d: question-answers'],
    'Science': ['Chapter %d: answer the in-text questions', 'Draw a labelled diagram of the human heart',
                'Prepare notes on "Sources of Energy"'],
    'Social Science': ['Chapter %d: map work in the atlas', 'Make a timeline of the Mughal emperors',
                       'Answer the back exercise of Lesson %d'],
    'Sanskrit': ['Shabd roop: "Balak" yaad kijiye', 'Path %d ka anuvaad likhiye'],
    'Computer': ['Write 5 uses of a computer', 'Learn the parts of the keyboard'],
    'General Knowledge': ['Collect 5 news headlines of this week', 'Learn the names of 10 Indian states and capitals'],
}
HOMEWORK = []   # class, subject, assigned, due, title
hw_days = [d for d in (TODAY - dt.timedelta(days=i) for i in range(16, -1, -1))
           if d.weekday() != 6 and d.isoformat() not in dict(HOLIDAYS)]
for c in CLASSES:
    subs = [x for x in SUBJECTS_OF[c] if x in HW]
    for d in hw_days:
        for sb in R.sample(subs, 1 if c in PRE else 2):
            title = R.choice(HW[sb])
            if '%d' in title:
                title = title % R.randint(3, 9)
            due = d + dt.timedelta(days=2 if d.weekday() < 4 else 3)
            HOMEWORK.append((c, sb, d.isoformat(), due.isoformat(), title))
emit("""
-- ── 18. Homework of the last two weeks, checked where it was due ──
CREATE TEMP TABLE d_homework (cls text, subj text, assigned date, due date, title text);
INSERT INTO d_homework VALUES
{rows};
DO $$
DECLARE h record; r refcursor; v_id int; v_ids int[]; v_st text[];
BEGIN
    FOR h IN SELECT dh.*, sec.academic_class_section_id sec_id, sb.subject_id, COALESCE(stf.user_id, {A}) uid
               FROM d_homework dh
               JOIN academic.academic_classes c ON c.school_id = {S} AND c.class_name = dh.cls
               JOIN academic.academic_class_sections sec ON sec.academic_class_id = c.academic_class_id
               JOIN academic.school_subjects sb ON sb.school_id = {S} AND sb.subject_name = dh.subj
               LEFT JOIN core.staff stf ON stf.staff_id = sec.class_teacher_staff_id
              ORDER BY dh.assigned LOOP
        CALL academic.sp_homework_manage('Save', {T}, {S}, h.uid, TRUE, NULL, h.sec_id, h.subject_id, h.title,
                                         NULL, h.assigned, h.due, FALSE, NULL, NULL, NULL, r);
        CLOSE r;
        SELECT max(homework_id) INTO v_id FROM academic.homework WHERE school_id = {S} AND academic_class_section_id = h.sec_id;
        -- given by the subject's teacher in that class (from the timetable), else the class teacher
        UPDATE academic.homework hw SET created_at = h.assigned + time '13:40',
               staff_id = COALESCE((SELECT t.staff_id FROM academic.timetable t
                                     WHERE t.academic_class_section_id = h.sec_id AND t.subject_id = h.subject_id LIMIT 1),
                                   (SELECT class_teacher_staff_id FROM academic.academic_class_sections WHERE academic_class_section_id = h.sec_id))
         WHERE homework_id = v_id;
        IF h.due < DATE __TODAY__ THEN
            SELECT array_agg(st.student_id), array_agg(CASE WHEN abs(hashtext(st.admission_no || v_id)) % 9 = 0 THEN 'NotDone' ELSE 'Done' END)
              INTO v_ids, v_st
              FROM core.students st WHERE st.school_id = {S} AND st.class_name = h.cls AND st.is_active;
            CALL academic.sp_homework_manage('Check', {T}, {S}, h.uid, TRUE, v_id, NULL, NULL, NULL, NULL, NULL, NULL, FALSE,
                                             v_ids, v_st, NULL, r);
            CLOSE r;
        END IF;
    END LOOP;
END $$;
""".format(T=T, S=S, A=ADMIN, rows=rows(HOMEWORK)))

# ── enquiries (some registered), front office ──
LEADS = ['Walk-in', 'Walk-in', 'Phone Call', 'Reference', 'Facebook', 'Website', 'Banner / Hoarding', 'Newspaper']
STAGES = (['New'] * 6 + ['Follow-up Pending'] * 7 + ['Interested'] * 6 + ['Campus Visit Scheduled'] * 4 +
          ['Registered'] * 5 + ['Not Interested'] * 4)
ENQUIRIES = []
for i, stage in enumerate(STAGES):
    girl = R.random() < 0.5
    sur = R.choice([x for x in SURNAMES if x not in MUSLIM])
    first = R.choice([n for n in (GIRLS if girl else BOYS) if n not in SIKH_FIRST])
    cls = R.choice(['Nursery', 'Nursery', 'LKG', 'UKG', 'Class 1', 'Class 2', 'Class 4', 'Class 6', 'Class 6', 'Class 7'])
    made = TODAY - dt.timedelta(days=R.randint(2, 70))
    nxt = None
    if stage in ('New', 'Follow-up Pending', 'Interested', 'Campus Visit Scheduled'):
        nxt = TODAY + dt.timedelta(days=R.randint(-4, 9))
    area, pin = R.choice(AREAS)
    ENQUIRIES.append(dict(
        name=first + ' ' + sur, gender='Female' if girl else 'Male', cls=cls, father=R.choice(FATHERS) + ' ' + sur,
        mother=R.choice(MOTHERS) + ' ' + sur, mobile=phone(), area=area, lead=R.choice(LEADS), stage=stage,
        priority=R.choice(['High', 'Medium', 'Medium', 'Low']), made=made, next=nxt,
        dob=dt.date(2026 - AGE0[cls] - 1, R.randint(4, 12), R.randint(1, 28)),
        notes=R.choice(['Father wants to see the classrooms first.', 'Asked about the transport route to their area.',
                        'Comparing fee with two nearby schools.', 'Sibling studies elsewhere, may shift both.',
                        'Wants admission after Diwali.', 'Mother asked about the Nursery timings.',
                        'Needs a seat in the school van.', 'Shifting from Ghaziabad next month.']),
        lost='Fee is higher than expected' if stage == 'Not Interested' else None,
        current=R.choice(['Saint Mary Convent', 'Govt. Sarvodaya Vidyalaya', 'Little Flowers Play School', None])))

emit("""
-- ── 19. Enquiries (about three in ten registered), with their dates ──
CREATE TEMP TABLE d_enquiries (name text, gender text, dob date, cls text, father text, mother text, mobile text, area text,
    lead text, stage text, priority text, made date, nxt date, notes text, lost text, current_school text);
INSERT INTO d_enquiries VALUES
{rows};
DO $$
DECLARE e record; r refcursor; v_id int;
BEGIN
    FOR e IN SELECT * FROM d_enquiries ORDER BY made LOOP
        CALL core.sp_enquiry_crm_manage(
            p_operation => 'SaveEnquiry', p_tenant_id => {T}, p_school_id => {S}, p_action_user_id => {REC},
            p_student_name => e.name, p_gender => e.gender, p_dob => e.dob, p_class_name => e.cls, p_session => {Y},
            p_parent_name => e.father, p_father_name => e.father, p_father_mobile => e.mobile, p_mother_name => e.mother,
            p_mobile => e.mobile, p_city => 'Delhi', p_area_locality => e.area, p_lead_source => e.lead,
            p_priority => e.priority, p_status => CASE WHEN e.stage = 'Registered' THEN 'Interested' ELSE e.stage END,
            p_assigned_to_id => {REC}, p_lost_reason => e.lost, p_next_followup_date => e.nxt, p_notes => e.notes,
            p_current_school => e.current_school, p_transport_required => e.area LIKE '%Burari%', p_result => r);
        CLOSE r;
        SELECT max(enquiry_id) INTO v_id FROM core.enquiries WHERE school_id = {S};
        UPDATE core.enquiries SET created_at = e.made + time '11:15', enquiry_date = e.made::text WHERE enquiry_id = v_id;
        IF e.stage = 'Registered' THEN
            CALL core.sp_enquiry_register({T}, {S}, {REC}, v_id, NULL, e.made + 3, FALSE, TRUE, 'REG-', r); CLOSE r;
            CALL core.sp_registration_fee_record({T}, {S}, {REC}, v_id, 500, 'Cash', NULL, 'Registration fee', e.made + 3,
                                                 NULL, 0, NULL, NULL, 500, r); CLOSE r;
        END IF;
    END LOOP;
END $$;
""".format(T=T, S=S, REC=REC_U, Y=q(YEAR),
           rows=rows([(e['name'], e['gender'], e['dob'].isoformat(), e['cls'], e['father'], e['mother'], e['mobile'],
                       e['area'], e['lead'], e['stage'], e['priority'], e['made'].isoformat(),
                       e['next'].isoformat() if e['next'] else None, e['notes'], e['lost'], e['current'])
                      for e in ENQUIRIES])))

VISITORS = [('Ramesh Gupta', 'Fee enquiry', 'Accountant', 1), ('Sunita Devi', 'Meet class teacher', 'Class Teacher', 2),
            ('Courier (Blue Dart)', 'Delivery', 'Office', 1), ('Inspector, DoE', 'Inspection', 'Principal', 2),
            ('Anil Verma', 'Admission enquiry', 'Reception', 3), ('Book seller (Sharma Book Depot)', 'Supply', 'Store', 1),
            ('Pooja Saini', 'Collect TC', 'Office', 1), ('Electrician', 'Repair work', 'Office', 1),
            ('Vikas Bansal', 'Meet Principal', 'Principal', 2), ('Mother of Diya Arora', 'Child unwell, early pick-up', 'Class Teacher', 1)]
CALLS = [('Rakesh Yadav', 'Incoming', 'Asked about bus timing on Route 1'), ('Shalini Jain', 'Incoming', 'Admission for Nursery'),
         ('Sharma Book Depot', 'Outgoing', 'Pending Class 6 book sets'), ('Neha Kapoor', 'Incoming', 'Fee receipt lost, needs copy'),
         ('Kapoor Uniforms', 'Outgoing', 'Winter sweater delivery date'), ('Parent of Aarav Mehra', 'Incoming', 'Leave for 3 days')]
COMPLAINTS = [('Rajeev Sharma', 'Transport', 'Bus was 25 minutes late on Monday', 'Resolved'),
              ('Mamta Chauhan', 'Facilities', 'Water cooler on 1st floor not working', 'Resolved'),
              ('Pradeep Negi', 'Academics', 'Child\'s notebook not checked for a week', 'Open')]
emit("""
-- ── 20. Front office: visitors, phone calls, complaints ──
DO $$
DECLARE r refcursor; v_id int; v_day date;
BEGIN""")
for i, (n, pur, meet, pp) in enumerate(VISITORS):
    day = TODAY - dt.timedelta(days=[0, 0, 0, 1, 1, 2, 3, 4, 5, 6][i])
    emit("""  CALL core.sp_front_office_manage('VisitorSave', {T}, {S}, {REC}, NULL, NULL, NULL, {n}, {m}, {p}, {meet}, {pp}, 'Aadhaar', NULL, NULL, NULL, NULL, NULL, r); CLOSE r;
  SELECT max(visitor_id) INTO v_id FROM core.fo_visitors WHERE school_id = {S};
  UPDATE core.fo_visitors SET visit_date = {d}, time_in = {d}::date + time '{h}:{mm}', time_out = CASE WHEN {out} THEN {d}::date + time '{h}:{mm}' + interval '35 minutes' END WHERE visitor_id = v_id;""".format(
        T=T, S=S, REC=REC_U, n=q(n), m=q(phone()), p=q(pur), meet=q(meet), pp=pp, d=q(day.isoformat()),
        h='%02d' % R.randint(8, 13), mm='%02d' % R.randint(0, 59), out='TRUE' if i > 1 else 'FALSE'))
for i, (n, dirn, pur) in enumerate(CALLS):
    day = TODAY - dt.timedelta(days=i)
    emit("""  CALL core.sp_front_office_manage('CallSave', {T}, {S}, {REC}, NULL, NULL, NULL, {n}, {m}, {p}, NULL, NULL, NULL, NULL, {dirn}, {fu}, NULL, NULL, r); CLOSE r;
  UPDATE core.fo_calls SET call_date = {d}, created_at = {d}::date + time '10:20' WHERE call_id = (SELECT max(call_id) FROM core.fo_calls WHERE school_id = {S});""".format(
        T=T, S=S, REC=REC_U, n=q(n), m=q(phone()), p=q(pur), dirn=q(dirn), d=q(day.isoformat()),
        fu=q((TODAY + dt.timedelta(days=2)).isoformat()) if i in (1, 3) else 'NULL'))
for i, (n, cat, issue, st) in enumerate(COMPLAINTS):
    day = TODAY - dt.timedelta(days=[9, 5, 1][i])
    emit("""  CALL core.sp_front_office_manage('ComplaintSave', {T}, {S}, {REC}, NULL, NULL, NULL, {n}, {m}, {cat}, NULL, NULL, NULL, {issue}, 'Parent', NULL, NULL, NULL, r); CLOSE r;
  SELECT max(complaint_id) INTO v_id FROM core.fo_complaints WHERE school_id = {S};
  UPDATE core.fo_complaints SET raised_on = {d}, created_at = {d}::date + time '12:00' WHERE complaint_id = v_id;""".format(
        T=T, S=S, REC=REC_U, n=q(n), m=q(phone()), cat=q(cat), issue=q(issue), d=q(day.isoformat())))
    if st == 'Resolved':
        emit("""  CALL core.sp_front_office_manage('ComplaintStatus', {T}, {S}, {A}, v_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Spoke to the parent; fixed the next day.', NULL, NULL, NULL, 'Resolved', r); CLOSE r;""".format(
            T=T, S=S, A=ADMIN))
emit("END $$;")

# ── notices, events ──
NOTICES = [
    ('Dussehra Holiday', 'The school will remain closed on Tuesday, 20 October 2026 on account of Dussehra. Classes resume on Wednesday, 21 October.', 'Holiday', 'Everyone', True, '2026-10-21', 2),
    ('Second instalment reminder', 'Parents are requested to clear the fee up to October by 25 October 2026 to avoid the late fine of Rs 100 per month.', 'Fee', 'Parents', False, '2026-10-31', 4),
    ('Unit Test 2 datesheet', 'Unit Test 2 for Classes 1 to 8 will be held from 16 to 21 November 2026. The datesheet is available in the school diary and on the app.', 'Exam', 'Parents', False, '2026-11-21', 6),
    ('Parent-Teacher Meeting', 'PTM for all classes will be held on Saturday, 7 November 2026 from 9:00 AM to 12:00 PM. Half Yearly report cards will be shared.', 'PTM', 'Everyone', True, '2026-11-07', 3),
    ('Winter uniform from 2 November', 'Students will wear the full winter uniform (sweater/blazer) from Monday, 2 November 2026.', 'Circular', 'Parents', False, '2026-11-15', 8),
    ('Staff meeting', 'All teachers to attend the staff meeting in the library on Friday at 2:30 PM to plan the Annual Day.', 'General', 'Staff', False, '2026-10-24', 1),
    ('Annual Sports Day', 'Annual Sports Day will be held on 12 December 2026. House-wise practice begins from 2 November.', 'Event', 'Everyone', False, '2026-12-12', 10),
    ('Independence Day celebration', 'Independence Day was celebrated with a march past, patriotic songs and a skit by Class 7. Thank you, parents, for coming.', 'Event', 'Everyone', False, '2026-08-31', 65),
]
emit("""
-- ── 21. Notices and events ──
DO $$
DECLARE r refcursor; v_id int;
BEGIN""")
for t, body, cat, aud, pin, until, ago in NOTICES:
    emit("""  CALL core.sp_announcement_manage('Save', {T}, {S}, {A}, NULL, {t}, {b}, {c}, {a}, NULL, {p}, {u}::date, r); CLOSE r;
  UPDATE core.announcements SET created_at = CURRENT_DATE - {ago} + time '08:40', show_until = {end}::date
   WHERE announcement_id = (SELECT max(announcement_id) FROM core.announcements WHERE school_id = {S});""".format(
        T=T, S=S, A=ADMIN, t=q(t), b=q(body), c=q(cat), a=q(aud), p=q(pin),
        u=q(until) if until >= TODAY.isoformat() else 'NULL', end=q(until), ago=ago))
EVENTS = [('Parent-Teacher Meeting', 'PTM', '2026-11-07', '2026-11-07', '09:00', '12:00', 'All parents', 'Half Yearly report cards'),
          ('Children\'s Day Celebration', 'Event', '2026-11-14', '2026-11-14', '09:00', '12:00', 'All students', 'Teachers\' performance and games'),
          ('Annual Sports Day', 'Sports', '2026-12-12', '2026-12-12', '08:30', '13:30', 'Classes 1-8', 'House-wise events'),
          ('Science Exhibition', 'Event', '2027-01-23', '2027-01-23', '10:00', '13:00', 'Classes 5-8', 'Projects on energy and environment'),
          ('Annual Day', 'Event', '2027-02-13', '2027-02-13', '16:00', '19:00', 'Parents and students', 'Cultural programme and prize distribution')]
for t, typ, a, b, st, et, who, notes in EVENTS:
    emit("""  CALL academic.sp_school_events_manage('Save', {T}, {S}, {A}, NULL, {t}, {ty}, {a}::date, {b}::date, {st}::time, {et}::time, {w}, {n}, r); CLOSE r;""".format(
        T=T, S=S, A=ADMIN, t=q(t), ty=q(typ), a=q(a), b=q(b), st=q(st), et=q(et), w=q(who), n=q(notes)))
emit("END $$;")

# ── expenses, cash book opening ──
EXP_CATS = ['Electricity', 'Water', 'Internet & Phone', 'Diesel (Buses)', 'Bus Maintenance', 'Building Repair',
            'Printing & Stationery', 'Housekeeping', 'Functions & Events', 'Sports', 'Miscellaneous']
EXPENSES = []
for m in range(4, 11):
    last = 17 if m == 10 else 28
    EXPENSES.append((dt.date(2026, m, min(10, last)), 'Electricity', R.randint(18000, 32000) if m in (5, 6, 7, 8) else R.randint(9000, 15000), 'BSES Yamuna Power', 'Bank Transfer'))
    EXPENSES.append((dt.date(2026, m, min(12, last)), 'Internet & Phone', 1499, 'Airtel Broadband', 'UPI'))
    EXPENSES.append((dt.date(2026, m, min(15, last)), 'Water', R.randint(900, 1600), 'Delhi Jal Board', 'Cash'))
    for w in (3, 11, 18, 25):
        if w <= last and not (m == 6) and not (m == 5 and w > 15):
            EXPENSES.append((dt.date(2026, m, w), 'Diesel (Buses)', R.randint(6500, 9500), 'Indian Oil, Burari', 'Cash'))
    if R.random() < 0.6:
        EXPENSES.append((dt.date(2026, m, R.randint(1, last)), 'Housekeeping', R.randint(1200, 3500), 'Shree Ganesh Traders', 'Cash'))
    if R.random() < 0.5:
        EXPENSES.append((dt.date(2026, m, R.randint(1, last)), 'Printing & Stationery', R.randint(800, 4200), 'Delhi Stationery Mart', 'Cash'))
EXPENSES += [(dt.date(2026, 6, 20), 'Building Repair', 48500, 'Painting contractor (Mohd. Akram)', 'Cheque'),
             (dt.date(2026, 7, 8), 'Bus Maintenance', 12800, 'Raju Motors, Mukundpur', 'Cash'),
             (dt.date(2026, 8, 14), 'Functions & Events', 9500, 'Independence Day decoration & sweets', 'Cash'),
             (dt.date(2026, 9, 2), 'Sports', 6200, 'Kapoor Sports, Kamla Nagar', 'UPI'),
             (dt.date(2026, 10, 9), 'Bus Maintenance', 7400, 'Tyre change - DL1PB 7783', 'Cash')]
emit("""
-- ── 22. Expenses and the cash book's opening balance ──
DO $$
DECLARE r refcursor;
BEGIN
  CALL core.sp_expense_manage('SetOpening', {T}, {S}, {A}, NULL, DATE '2026-04-01', NULL, 42500, 386000, NULL, NULL, NULL, 'Balance carried from March 2026', NULL, NULL, NULL, NULL, r); CLOSE r;""".format(T=T, S=S, A=ADMIN))
for c in EXP_CATS:
    emit("""  IF NOT EXISTS (SELECT 1 FROM core.expense_categories WHERE school_id = {S} AND lower(name) = lower({n})) THEN
    CALL core.sp_expense_manage('SaveCategory', {T}, {S}, {A}, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, {n}, TRUE, NULL, NULL, r); CLOSE r;
  END IF;""".format(
        T=T, S=S, A=ADMIN, n=q(c)))
emit("END $$;")
emit("""
CREATE TEMP TABLE d_expenses (d date, cat text, amt numeric, paid_to text, mode text);
INSERT INTO d_expenses VALUES
{rows};
DO $$
DECLARE x record; r refcursor;
BEGIN
    FOR x IN SELECT e.*, c.category_id FROM d_expenses e
               JOIN core.expense_categories c ON c.school_id = {S} AND c.name = e.cat ORDER BY e.d LOOP
        CALL core.sp_expense_manage('Save', {T}, {S}, {ACC}, NULL, x.d, x.category_id, x.amt, NULL, x.mode, x.paid_to,
                                    NULL, NULL, NULL, NULL, NULL, NULL, r);
        CLOSE r;
    END LOOP;
""".format(T=T, S=S, ACC=ACC_U, rows=rows([(d.isoformat(), c, amt, to, mode) for d, c, amt, to, mode in sorted(EXPENSES)])))
emit("END $$;")

# ── two children who left (with a TC), certificates, rooms, fee follow-ups, day close ──
LEAVERS = [  # name, gender, class, dob, father, mother, left on, why
    ('Kunal Saini', 'Male', 'Class 4', '2016-08-12', 'Satish Saini', 'Renu Saini', '2026-09-15', 'Family moved to Jaipur (father transferred)'),
    ('Riya Bisht', 'Female', 'Class 7', '2013-05-03', 'Mahesh Bisht', 'Geeta Bisht', '2026-08-31', 'Shifted to Dehradun'),
]
emit("""
-- ── 23. Two children who left this session (exit + Transfer Certificate) ──
DO $$
DECLARE r refcursor; v_res record; v_plan jsonb; v_id int; v_items jsonb; l record;
BEGIN""")
for i, (n, g, c, dob, f, mo, left, why) in enumerate(LEAVERS):
    emit("""  SELECT jsonb_agg(jsonb_build_object('feeHeadId', fd.fee_head_id, 'feeHeadName', fd.fee_head_name, 'frequency', fd.frequency,
                                        'amount', fd.amount, 'isOptional', FALSE)) INTO v_plan
    FROM core.school_fee_structure_details fd JOIN core.school_fee_structures fs ON fs.fee_structure_id = fd.fee_structure_id
   WHERE fs.school_id = {S} AND fs.class_name = {c} AND fd.frequency <> 'One Time';
  CALL core.sp_admission_manage(p_operation => 'SaveAdmission', p_tenant_id => {T}, p_school_id => {S}, p_action_user_id => {A},
       p_admission_no => {adm}, p_student_name => {n}, p_gender => {g}, p_dob => {dob}::date, p_class_name => {c}, p_section => 'A',
       p_academic_year => {Y}, p_admission_date => DATE '2026-04-01', p_guardian_name => {f}, p_mother_name => {mo},
       p_mobile => {m}, p_address => {addr}, p_religion => 'Hindu', p_category => 'General', p_nationality => 'Indian',
       p_fee_plan_json => v_plan, p_result => r);
  FETCH r INTO v_res; CLOSE r;
  v_id := v_res.student_id;
  UPDATE core.students SET admission_date = DATE '{since}-04-05', roll_no = '21' WHERE student_id = v_id;
  -- fees paid up to the month they left
  SELECT jsonb_agg(jsonb_build_object('ledgerId', ledger_id, 'amount', amount_due - amount_paid, 'concession', 0)) INTO v_items
    FROM core.student_ledger WHERE student_id = v_id AND due_date::date <= {left}::date;
  CALL core.sp_fee_payment_collect(p_tenant_id => {T}, p_school_id => {S}, p_action_user_id => {ACC}, p_student_id => v_id,
       p_items => v_items, p_extras => '[]'::jsonb, p_payment_mode => 'Cash', p_payment_date => {left}::date - 6, p_result => r);
  CLOSE r;
  CALL core.sp_student_exit('Exit', {T}, {S}, {A}, v_id, 'Transfer', {left}::date, {why}, r); CLOSE r;
  CALL core.sp_tc_manage(p_operation => 'Issue', p_tenant_id => {T}, p_school_id => {S}, p_action_user_id => {A}, p_student_id => v_id,
       p_format => 'Basic', p_conduct => 'Good', p_result => 'Promoted', p_reason => {why}, p_remarks => NULL,
       p_fees_paid_upto => {upto}, p_result_cur => r);
  CLOSE r;""".format(T=T, S=S, A=ADMIN, ACC=ACC_U, Y=q(YEAR), adm=q('APS/20%d/%03d' % (21 + i, 90 + i)), n=q(n), g=q(g),
                     dob=q(dob), c=q(c), f=q(f), mo=q(mo), m=q(phone()), addr=q('H.No. %d, Sant Nagar, Burari, Delhi - 110084' % (40 + i)),
                     left=q(left), why=q(why), since=2021 + i, upto=q(dt.date.fromisoformat(left).strftime('%B %Y'))))
emit("END $$;")

CERTS = [('Bonafide', 'Bank account opening'), ('Bonafide', 'Passport application'), ('Character', 'Scholarship form'),
         ('Bonafide', 'Railway concession'), ('Character', 'Sports trials'), ('Bonafide', 'Aadhaar update')]
emit("""
-- ── 24. Certificates, rooms, fee follow-ups, a child not chased, day close ──
DO $$
DECLARE r refcursor; v_id int; d record;
BEGIN""")
for typ, why in CERTS:
    emit("""  SELECT student_id INTO v_id FROM core.students WHERE school_id = {S} AND is_active AND class_name = {c} ORDER BY student_id OFFSET {o} LIMIT 1;
  CALL core.sp_certificate_manage('Issue', {T}, {S}, {A}, NULL, v_id, {t}, {w}, 'Good', NULL, NULL, r); CLOSE r;""".format(
        T=T, S=S, A=ADMIN, c=q(R.choice(CLASSES[3:])), o=R.randint(0, 19), t=q(typ), w=q(why)))
ROOMS = [('Room %d' % (i + 1), 'Classroom', 32, 'Main Block' if i < 6 else 'New Block') for i in range(len(CLASSES))]
ROOMS += [('Computer Lab', 'Lab', 25, 'New Block'), ('Activity Room', 'Hall', 30, 'Main Block'),
          ('Ground', 'Other', 200, 'Campus'), ('Library', 'Library', 40, 'Main Block'), ('Staff Room', 'Staff room', 20, 'Main Block')]
for n, typ, cap, bld in ROOMS:
    emit("""  CALL academic.sp_room_manage('Save', {T}, {S}, {A}, NULL, {n}, {t}, {c}, {b}, NULL, r); CLOSE r;""".format(
        T=T, S=S, A=ADMIN, n=q(n), t=q(typ), c=cap, b=q(bld)))
emit("""
  -- what the office was told by families that owe for months
  FOR d IN SELECT st.student_id, row_number() OVER (ORDER BY st.student_id) n
             FROM d_students ds JOIN core.students st ON st.school_id = {S} AND st.admission_no = ds.adm
            WHERE ds.payer = 'defaulter' LIMIT 7 LOOP
      CALL core.sp_fee_followup('Add', {T}, {S}, {ACC}, d.student_id,
           (ARRAY['Father will pay after salary on the 1st', 'Mother said they will pay two months next week',
                  'Phone not answered, message left', 'Will pay at the PTM', 'Asked for one more week',
                  'Paying in two parts, first part on Saturday', 'Father out of station, will pay on return'])[d.n],
           (CURRENT_DATE + (d.n * 3)::int)::text, NULL, r);
      CLOSE r;
  END LOOP;
  -- a staff child the office does not chase
  SELECT st.student_id INTO v_id FROM core.students st WHERE st.school_id = {S} AND st.is_active AND st.class_name = 'Class 2'
   ORDER BY st.student_id LIMIT 1;
  CALL core.sp_fee_no_chase('Set', {T}, {S}, {A}, v_id, 'Staff ward - fee adjusted from salary', NULL, r); CLOSE r;

  -- the accountant closes his counter every day he took money (up to last Friday)
  FOR d IN SELECT payment_date::date pd, sum(amount) FILTER (WHERE payment_mode = 'Cash') cash
             FROM core.fee_payments WHERE school_id = {S} AND created_by = {ACC} AND NOT COALESCE(is_cancelled, FALSE)
              AND payment_date::date <= DATE __TODAY__ - 3
            GROUP BY 1 ORDER BY 1 LOOP
      CALL core.sp_fee_day_close({T}, {S}, {ACC}, d.pd, COALESCE(d.cash, 0), NULL, r); CLOSE r;
  END LOOP;
END $$;

-- ── 25. A few things every school has: the principal's own login, October's salary
-- worked out (not yet paid), one teacher who left, a second store with transfers ──
UPDATE core.staff SET user_id = {A} WHERE school_id = {S} AND full_name = 'Neelam Sharma';
DO $$
DECLARE r refcursor; v_loc int; v_main int; v_item int; v_staff int;
BEGIN
  CALL core.sp_staff_payroll_manage('RUN', {T}, {S}, {A}, 10, 2026, NULL, NULL, r); CLOSE r;

  INSERT INTO core.staff (tenant_id, school_id, employee_code, full_name, gender, dob, mobile, staff_type, department,
                          designation, joining_date, qualification, experience_years, status, monthly_salary, is_active,
                          status_changed_at, last_working_date, created_by)
  VALUES ({T}, {S}, 'APS-EMP-032', 'Anjali Mehra', 'Female', DATE '1994-02-11', '9000077001', 'Teaching', 'Academic', 'PRT',
          DATE '2022-04-01', 'B.A., B.Ed.', 4, 'Inactive', 19000, FALSE, TIMESTAMPTZ '2026-07-31 17:00', DATE '2026-07-31', {A});

  CALL core.sp_inventory_manage('SAVELOCATION', {T}, {S}, {A}, p_location_name => 'Primary Wing Store', p_result => r); CLOSE r;
  SELECT location_id INTO v_loc FROM core.inventory_locations WHERE school_id = {S} AND location_name = 'Primary Wing Store';
  SELECT location_id INTO v_main FROM core.inventory_locations WHERE school_id = {S} AND location_id <> v_loc ORDER BY location_id LIMIT 1;
  SELECT item_id INTO v_item FROM core.inventory_items WHERE school_id = {S} AND item_name = 'Chalk Box (White)';
  CALL core.sp_inventory_manage('TRANSFER', {T}, {S}, {A}, p_item_id => v_item, p_quantity => 25, p_location_id => v_main,
       p_to_location_id => v_loc, p_remarks => 'For the primary block', p_result => r); CLOSE r;
  SELECT item_id INTO v_item FROM core.inventory_items WHERE school_id = {S} AND item_name = 'Whiteboard Marker';
  CALL core.sp_inventory_manage('TRANSFER', {T}, {S}, {A}, p_item_id => v_item, p_quantity => 40, p_location_id => v_main,
       p_to_location_id => v_loc, p_remarks => 'For the primary block', p_result => r); CLOSE r;
END $$;

-- back to normal: attendance can again be entered only 7 days back
UPDATE core.school_settings SET attendance_backdate_days = 7 WHERE school_id = {S};
""".format(T=T, S=S, A=ADMIN, ACC=ACC_U))

import os
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'demo_school_seed.sql'), 'w', encoding='utf-8', newline='\n') as f:
    sql = '\n'.join(out) + '\n'
    # the day the demo is built (months after March roll into the next calendar year)
    month_no = TODAY.month if TODAY.year == 2026 else TODAY.month + 12
    sql = sql.replace('__TODAY_MONTH__', str(month_no)).replace('__TODAY__', "'" + TODAY.isoformat() + "'")
    f.write(sql)
