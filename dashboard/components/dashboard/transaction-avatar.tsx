import {
  IconFood, IconTransport, IconHealth, IconEntertainment, IconShopping,
  IconUtilities, IconRepeat, IconTravel, IconIncome, IconTransfer, IconOther, IconMusic, IconGift, IconWine,
} from "@/components/icons"

const categories = {
  food: { Icon: IconFood, background: "#c2410c" },
  transport: { Icon: IconTransport, background: "#0369a1" },
  health: { Icon: IconHealth, background: "#be185d" },
  entertainment: { Icon: IconEntertainment, background: "#7e22ce" },
  shopping: { Icon: IconShopping, background: "#b45309" },
  utilities: { Icon: IconUtilities, background: "#0f766e" },
  subscriptions: { Icon: IconRepeat, background: "#4f46e5" },
  travel: { Icon: IconTravel, background: "#0e7490" },
  income: { Icon: IconIncome, background: "#15803d" },
  transfer: { Icon: IconTransfer, background: "#475569" },
  other: { Icon: IconOther, background: "#6b7280" },
}

const normalize = (value: string) => value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase()

export function TransactionAvatar({ label, category }: { label: string; category: string }) {
  const merchant = normalize(label)
  const name = normalize(category)
  const overrides = [
    { pattern: /airbnb|hotel|rancho|pousada/, ...categories.travel },
    { pattern: /vivara|joia|jewel/, Icon: IconGift, background: "#be185d" },
    { pattern: /localiza/, ...categories.transport },
    { pattern: /vinicola|wine|vinho/, Icon: IconWine, background: "#9f1239" },
    { pattern: /99food|restaur|chateau/, ...categories.food },
    { pattern: /ifood|i food/, ...categories.food, background: "#dc2626" },
    { pattern: /uber\s*eats/, ...categories.food },
    { pattern: /uber|99app|99pop/, ...categories.transport, background: "#262626" },
    { pattern: /wellhub|gympass/, ...categories.health, background: "#be185d" },
    { pattern: /spotify/, Icon: IconMusic, background: "#15803d" },
    { pattern: /apple/, ...categories.subscriptions, background: "#52525b" },
    { pattern: /amazon/, ...categories.shopping, background: "#b45309" },
    { pattern: /netflix|disney|hbo|max\.com/, ...categories.entertainment },
  ]
  const matches: [RegExp, keyof typeof categories][] = [
    [/food|alimenta|restaur|mercado|grocer|supermerc|lanche|delivery/, "food"],
    [/transport|mobilidade|combust|fuel|carro|estacion/, "transport"],
    [/health|saude|farmac|medic|academia|fitness/, "health"],
    [/entertainment|entreten|lazer|cinema|jogos/, "entertainment"],
    [/shopping|compras|vestuario|roupa/, "shopping"],
    [/bills|utilit|contas|moradia|energia|agua|internet|telefone/, "utilities"],
    [/subscription|assinatura|recorr/, "subscriptions"],
    [/travel|viage|hotel|turismo/, "travel"],
    [/income|receita|salario|rendimento/, "income"],
    [/transfer|pix/, "transfer"],
  ]
  const key = matches.find(([pattern]) => pattern.test(`${name} ${merchant}`))?.[1] ?? "other"
  const { Icon, background } = overrides.find(({ pattern }) => pattern.test(merchant)) ?? categories[key]
  return <span className="txAvatar" style={{ background: `${background}14`, color: background }} aria-hidden><Icon /></span>
}
