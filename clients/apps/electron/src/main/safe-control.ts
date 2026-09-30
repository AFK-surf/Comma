export function safelyRunControl(
  control: () => Promise<unknown> | unknown,
  onError: (error: unknown) => void
) {
  try {
    void Promise.resolve(control()).catch(onError);
  } catch (error) {
    onError(error);
  }
}
