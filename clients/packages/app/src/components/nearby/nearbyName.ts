/** “Ada’s Comma” is Ada; a name the person chose stays as it is. */
export const nearbyOwnerName = (airDropName: string) =>
  airDropName.replace(/’s Comma$/, "") || airDropName;
