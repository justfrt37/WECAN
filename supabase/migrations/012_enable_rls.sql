-- 012_enable_rls.sql
-- Supabase Advisor "RLS Disabled in Public" (CRITICAL) düzeltmesi.
-- Bu tablolarda RLS kapalıydı; client anon-key + kullanıcı JWT ile PostgREST
-- üzerinden okuduğu için (özellikle conversations: fetchConversations /
-- fetchConversationStates), RLS kapalıyken bir kullanıcı BAŞKALARININ
-- konuşmalarını da çekebiliyordu. Edge fonksiyonlar SERVICE_ROLE ile çalışıp
-- RLS'i baypas ettiğinden sunucu tarafı etkilenmez.

-- conversations: "conversations_own_read" policy'si ZATEN var
-- (auth.uid() = user_id). Yalnızca RLS'i açmak onu etkinleştirir.
alter table conversations enable row level security;

-- conversation_behaviors + shot_templates: client HİÇ erişmiyor (yalnızca
-- sunucu/service-role). RLS açık + policy yok → client erişimi kapalı,
-- sunucu baypas eder. (Global referans verisi; kullanıcıya özel değil.)
alter table conversation_behaviors enable row level security;
alter table shot_templates enable row level security;
