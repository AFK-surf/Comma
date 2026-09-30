/* Static SVG markup for the status-indicator segments, pre-rendered from the
   Comma central icons (CircleDashedIcon, LoaderIcon, BubbleAlertIcon,
   CircleCheckIcon, CircleXIcon in ../icons).

   These are inlined as strings so the app bundle never imports
   react-dom/server — a server renderer in a client bundle interferes with
   React's id/dispatcher internals (react-aria menus remount in a loop).
   Regenerate after an icon change with:

   npx tsx -e "
   import { createElement } from 'react';
   import { renderToStaticMarkup } from 'react-dom/server';
   import * as icons from './src/components/icons';
   console.log(renderToStaticMarkup(createElement(icons.CircleDashedIcon)));
   " (from clients/packages/ui, once per icon)
*/

export const statusIconMarkup = {
  backlog:
    '<svg data-comma-icon="" aria-hidden="true" width="24px" height="24px" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><mask id="round-outlined-radius-2-stroke-2-IconCircleDashed" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24"><rect width="24" height="24" fill="#000"></rect><g fill="none" style="color:#fff"><path d="M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" stroke-dasharray="3 4"></path></g></mask><rect width="24" height="24" fill="currentColor" mask="url(#round-outlined-radius-2-stroke-2-IconCircleDashed)"></rect></svg>',
  cancel:
    '<svg data-comma-icon="" aria-hidden="true" width="24px" height="24px" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><mask id="round-outlined-radius-2-stroke-2-IconCircleX" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24"><rect width="24" height="24" fill="#000"></rect><g fill="none" style="color:#fff"><path d="M15 9L9 15M15 15L9 9M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path></g></mask><rect width="24" height="24" fill="currentColor" mask="url(#round-outlined-radius-2-stroke-2-IconCircleX)"></rect></svg>',
  done: '<svg data-comma-icon="" aria-hidden="true" width="24px" height="24px" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><mask id="round-outlined-radius-2-stroke-2-IconCircleCheck" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24"><rect width="24" height="24" fill="#000"></rect><g fill="none" style="color:#fff"><path d="M15 9.5L10.5 15L8.5 13M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path></g></mask><rect width="24" height="24" fill="currentColor" mask="url(#round-outlined-radius-2-stroke-2-IconCircleCheck)"></rect></svg>',
  inProgress:
    '<svg data-comma-icon="" aria-hidden="true" width="24px" height="24px" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><mask id="round-outlined-radius-2-stroke-2-IconLoader" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24"><rect width="24" height="24" fill="#000"></rect><g fill="none" style="color:#fff"><path d="M12.0003 3V6M12.0003 18V21M5.63634 5.63604L7.75766 7.75736M16.2429 16.2426L18.3643 18.364M3 12.0007H6M18 12.0007H21M5.63634 18.364L7.75766 16.2426M16.2429 7.75736L18.3643 5.63604" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path></g></mask><rect width="24" height="24" fill="currentColor" mask="url(#round-outlined-radius-2-stroke-2-IconLoader)"></rect></svg>',
  needsReview:
    '<svg data-comma-icon="" aria-hidden="true" width="24px" height="24px" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><mask id="round-outlined-radius-2-stroke-2-IconBubbleAlert" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24"><rect width="24" height="24" fill="#000"></rect><g fill="none" style="color:#fff"><path d="M11.9998 8.5V10.5M11.9977 20.5358L14.7377 18.2657C14.9171 18.1171 15.1427 18.0358 15.3757 18.0358L18.002 18.0358C19.1065 18.0357 20.002 17.1403 20.002 16.0358V6C20.002 4.89543 19.1065 4 18.0019 4L6.00195 4.00002C4.89738 4.00002 4.00195 4.89545 4.00195 6.00002V16.0358C4.00195 17.1403 4.89738 18.0358 6.00195 18.0358H8.65157C8.8865 18.0358 9.11393 18.1185 9.29398 18.2694L11.9977 20.5358Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path><path d="M12 13.5H12.01M12.25 13.5C12.25 13.6381 12.1381 13.75 12 13.75C11.8619 13.75 11.75 13.6381 11.75 13.5C11.75 13.3619 11.8619 13.25 12 13.25C12.1381 13.25 12.25 13.3619 12.25 13.5Z" stroke="currentColor" stroke-width="2" stroke-linecap="round"></path></g></mask><rect width="24" height="24" fill="currentColor" mask="url(#round-outlined-radius-2-stroke-2-IconBubbleAlert)"></rect></svg>',
} as const;
