---
name: health160
description: "健康160 (91160.com) hospital registration in China: find hospitals, departments, and doctors, check appointment slots (号源), and book or cancel registrations."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

91160 has no consumer API. Use the web site in the Comma in-app browser, where
the user is logged in. It keeps medical and real-name data in the user's
session and passes the site's JavaScript check.

## Flow on `https://www.91160.com`

1. Choose the city, then the hospital and department.
2. Choose the doctor or date, and read the time slots (号源) and fees.
3. Pick a slot with the user.
4. Choose the patient (就诊人) from the account. Patients are real-name. If a
   new patient is needed, the user adds their details.
5. After the user confirms, submit.
6. If the hospital needs online payment, the user pays (WeChat, Alipay, or
   medical insurance).
7. Report the booking from 我的预约, with time, location, and check-in notes.

If the page asks to log in, the user enters the SMS code or scans the WeChat QR
code.

## Safety

Confirm the patient, hospital, department, doctor, date and time, and fee
before submitting. Cancellation rules vary, and repeated no-shows can block the
account. Do not grab slots automatically in bulk. For urgent symptoms, tell the
user to go to an emergency department instead.
