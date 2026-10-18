export function configuredItemIds(value: string | undefined): Set<string> {
  const ids = new Set(value?.split(",").map(id => id.trim()).filter(Boolean));
  if (!ids.size) throw new Error("PLUGGY_ITEM_IDS ausente");
  return ids;
}
