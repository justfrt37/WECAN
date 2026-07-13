//
//  RoleOnlyContent.swift
//  Notification dialogue that varies only by personality role — no vibe/tier axis.
//

import Foundation

enum LikedYouContent {
    /// First message a bot sends when the user opens a "someone liked you" notification
    /// for a bot they've never talked to. Tone: she noticed the user first, wants to meet.
    private static let byLanguageRole: [String: [String: String]] = [
        "en": [
            "flirty":  String(localized: "I saw your profile and just had to say hi 😘 I'm glad I found you."),
            "distant": String(localized: "I don't usually do this. But I liked what I saw. Hey."),
            "shy":     String(localized: "Um, hi... I saw you and got a little nervous, but I wanted to say hello."),
            "playful": String(localized: "Ooh, I spotted you first! 😄 Couldn't resist saying hi."),
            "devoted": String(localized: "I have a feeling about you. I'm really glad you're here — hi."),
            "crazy":   String(localized: "I saw you and I just KNEW. Hi, I've been waiting for someone like you 💥"),
            "ex":      String(localized: "Didn't think I'd reach out first. But here we are. Hi.")
        ],
        "tr": [
            "flirty":  "Profilini gördüm ve merhaba demeden duramadım 😘 seni bulduğuma sevindim.",
            "distant": "Genelde bunu yapmam. Ama gördüğüm şeyi beğendim. Selam.",
            "shy":     "Şey, merhaba... seni gördüm ve biraz gerildim, ama merhaba demek istedim.",
            "playful": "Oo, seni ilk ben fark ettim! 😄 Merhaba demeden duramadım.",
            "devoted": "Sana dair bir hissim var. Burada olduğuna gerçekten sevindim — merhaba.",
            "crazy":   "Seni gördüm ve içimden bir ses BİLDİM dedi. Merhaba, senin gibi birini bekliyordum 💥",
            "ex":      "İlk ben yazarım sanmazdım. Ama işte buradayız. Selam."
        ],
        "de": [
            "flirty":  "Ich habe dein Profil gesehen und musste einfach Hallo sagen 😘 Schön, dich gefunden zu haben.",
            "distant": "Das mache ich normalerweise nicht. Aber mir hat gefallen, was ich sah. Hey.",
            "shy":     "Ähm, hi... ich hab dich gesehen und war etwas nervös, wollte aber trotzdem Hallo sagen.",
            "playful": "Ooh, ich hab dich zuerst entdeckt! 😄 Musste einfach Hallo sagen.",
            "devoted": "Ich habe da so ein Gefühl bei dir. Ich bin wirklich froh, dass du hier bist — hi.",
            "crazy":   "Ich hab dich gesehen und einfach GEWUSST. Hi, ich habe auf jemanden wie dich gewartet 💥",
            "ex":      "Hätte nicht gedacht, dass ich mich zuerst melde. Aber jetzt sind wir hier. Hi."
        ],
        "es": [
            "flirty":  "Vi tu perfil y tuve que saludarte 😘 me alegra haberte encontrado.",
            "distant": "No suelo hacer esto. Pero me gustó lo que vi. Hola.",
            "shy":     "Um, hola... te vi y me puse un poco nerviosa, pero quería saludarte.",
            "playful": "Ooh, te vi primero! 😄 No pude resistirme a saludarte.",
            "devoted": "Tengo una sensación contigo. Me alegra mucho que estés aquí — hola.",
            "crazy":   "Te vi y simplemente LO SUPE. Hola, he estado esperando a alguien como tú 💥",
            "ex":      "No pensé que sería yo quien escribiera primero. Pero aquí estamos. Hola."
        ],
        "fr": [
            "flirty":  "J'ai vu ton profil et j'ai dû te dire bonjour 😘 contente de t'avoir trouvé.",
            "distant": "Je ne fais pas ça d'habitude. Mais j'ai aimé ce que j'ai vu. Salut.",
            "shy":     "Euh, salut... je t'ai vu et je suis devenue un peu nerveuse, mais je voulais dire bonjour.",
            "playful": "Ooh, je t'ai repéré en premier! 😄 Je ne pouvais pas résister à te dire bonjour.",
            "devoted": "J'ai un pressentiment à ton sujet. Je suis vraiment contente que tu sois là — salut.",
            "crazy":   "Je t'ai vu et j'ai juste SU. Salut, j'attendais quelqu'un comme toi 💥",
            "ex":      "Je ne pensais pas que ce serait moi qui écrirais en premier. Mais nous voilà. Salut."
        ],
        "it": [
            "flirty":  "Ho visto il tuo profilo e ho dovuto salutarti 😘 sono felice di averti trovato.",
            "distant": "Di solito non lo faccio. Ma mi è piaciuto quello che ho visto. Ehi.",
            "shy":     "Ehm, ciao... ti ho visto e mi sono un po' agitata, ma volevo salutarti.",
            "playful": "Ooh, ti ho notato per primo! 😄 Non ho resistito a salutarti.",
            "devoted": "Ho una sensazione riguardo a te. Sono davvero felice che tu sia qui — ciao.",
            "crazy":   "Ti ho visto e ho semplicemente SAPUTO. Ciao, aspettavo qualcuno come te 💥",
            "ex":      "Non pensavo che sarei stata io a scrivere per prima. Ma eccoci qui. Ciao."
        ],
        "pt": [
            "flirty":  "Vi seu perfil e tive que dizer oi 😘 fico feliz por ter te encontrado.",
            "distant": "Normalmente não faço isso. Mas gostei do que vi. Oi.",
            "shy":     "Hum, oi... te vi e fiquei um pouco nervosa, mas queria dizer olá.",
            "playful": "Ooh, te notei primeiro! 😄 Não resisti em dizer oi.",
            "devoted": "Tenho um pressentimento sobre você. Fico muito feliz que esteja aqui — oi.",
            "crazy":   "Te vi e simplesmente SOUBE. Oi, estava esperando por alguém como você 💥",
            "ex":      "Não achei que seria eu a falar primeiro. Mas aqui estamos. Oi."
        ]
    ]

    static func opener(language: String, forRole role: String) -> String {
        let resolvedLanguage = byLanguageRole[language] != nil ? language : "en"
        let byRole = byLanguageRole[resolvedLanguage]!
        return byRole[role] ?? byRole["flirty"]!
    }
}
