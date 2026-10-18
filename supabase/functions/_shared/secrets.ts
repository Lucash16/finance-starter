export async function getSecret(envName: string): Promise<string> {
  const value = Deno.env.get(envName);
  if (!value?.trim()) throw new Error(`Configuração ausente: ${envName}`);
  return value;
}
