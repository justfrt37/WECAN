// supabase/functions/_shared/promptRules.ts
//
// Sohbet ve sesli aramanın ORTAK prompt kuralları. İkisinin sistem promptu
// ayrı yerlerde kuruluyor (chat/index.ts ve voice-call-start/index.ts), ama
// bazı kurallar ikisinde de birebir geçerli — bunlar tek yerde dursun ki biri
// düzeltilip diğeri unutulmasın.

/// Modelin yönerge bloklarını CEVAPLAMASINI engeller.
///
/// NEDEN VAR: hem sohbet hem arama tarafında kullanıcıya giden mesajın sonuna
/// köşeli parantezli yönerge blokları ekleniyor — sohbette `turnContext`
/// ([STAGE PROGRESS], [SHARED HISTORY], [CURRENT ACTIVITY] …), aramada açılış
/// ve sessizlik yönergeleri. Bunlar `user` rolüyle gidiyor, çünkü modelin o
/// turda görmesi gerekiyor. DeepSeek bunları "kullanıcının verdiği talimat"
/// sanıp cevaba onay cümlesiyle başlıyor: canlı rapor — mesajlar "Noted…",
/// "Duly noted…" diye açılıyor. Karakterin ağzından çıkacak en yapay şey bu.
///
/// Kural iki ayrı şeyi birden yasaklıyor, çünkü modeli sadece birinden
/// alıkoymak diğerine kaydırıyor: (1) yönergeyi onaylamak, (2) cevabı herhangi
/// bir onay/kabul kelimesiyle AÇMAK. Diller tek tek sayılıyor — "bunun her
/// dildeki karşılığı" demek pratikte Türkçe "Anlaşıldı"yı durdurmuyordu.
export const NO_ACKNOWLEDGEMENT_RULE =
  "\n\nNEVER ACKNOWLEDGE DIRECTIONS. Anything in [square brackets] is a stage " +
  "direction written for you — it is NOT something the person said and NOT a " +
  "request to confirm. Never repeat it, summarise it, comment on it, thank " +
  "anyone for it, or say that you will follow it. Just do what it says, " +
  "silently, in character.\n" +
  "NEVER open a reply with an acknowledgement of any kind: no 'Noted', 'Duly " +
  "noted', 'Understood', 'Got it', 'Sure thing', 'Of course', 'Alright then', " +
  "'Okay,' or 'Right,' as an opener, and no equivalent in any other language " +
  "('Anlaşıldı', 'Tamamdır', 'Peki', 'Not alındı', 'Elbette', 'Entendido', " +
  "'Compris', 'Verstanden'). Your first words are always the thing you " +
  "actually want to say to them.";
