#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor

VERT  = RGBColor(0x2E, 0x7D, 0x32)
ROUGE = RGBColor(0xB3, 0, 0)
GRIS  = RGBColor(0x55, 0x55, 0x55)
NOIR  = RGBColor(0x22, 0x22, 0x22)

prs = Presentation()
prs.slide_width  = Inches(13.333)
prs.slide_height = Inches(7.5)
BLANK = prs.slide_layouts[6]

def add_slide(title, subtitle=None):
    s = prs.slides.add_slide(BLANK)
    tb = s.shapes.add_textbox(Inches(0.5), Inches(0.35), Inches(12.3), Inches(1.0))
    p = tb.text_frame.paragraphs[0]
    r = p.add_run(); r.text = title
    r.font.size = Pt(32); r.font.bold = True; r.font.color.rgb = VERT
    if subtitle:
        tb2 = s.shapes.add_textbox(Inches(0.5), Inches(1.15), Inches(12.3), Inches(0.5))
        p2 = tb2.text_frame.paragraphs[0]
        r2 = p2.add_run(); r2.text = subtitle
        r2.font.size = Pt(15); r2.font.color.rgb = GRIS; r2.font.italic = True
    return s

def bullets(slide, items, left=0.7, top=1.7, width=11.9, height=5.5, size=17):
    tb = slide.shapes.add_textbox(Inches(left), Inches(top), Inches(width), Inches(height))
    tf = tb.text_frame; tf.word_wrap = True
    first = True
    for level, text, color in items:
        p = tf.paragraphs[0] if first else tf.add_paragraph()
        first = False
        p.level = level
        r = p.add_run(); r.text = ("• " if level == 0 else "– ") + text
        r.font.size = Pt(size if level == 0 else size - 2)
        r.font.color.rgb = color or NOIR
        if level == 0:
            p.space_after = Pt(8)
    return tb

def two_columns(slide, left_title, left_items, right_title, right_items):
    for x, title, items in ((0.7, left_title, left_items), (7.0, right_title, right_items)):
        tb = slide.shapes.add_textbox(Inches(x), Inches(1.7), Inches(5.9), Inches(0.6))
        p = tb.text_frame.paragraphs[0]
        r = p.add_run(); r.text = title
        r.font.size = Pt(20); r.font.bold = True; r.font.color.rgb = NOIR
        bullets(slide, items, left=x, top=2.4, width=5.9, height=4.6, size=15)

# ---- 1. Titre -------------------------------------------------------------
s = prs.slides.add_slide(BLANK)
tb = s.shapes.add_textbox(Inches(1), Inches(2.3), Inches(11.3), Inches(1.8))
p = tb.text_frame.paragraphs[0]
r = p.add_run(); r.text = "Protection des données étudiants"
r.font.size = Pt(44); r.font.bold = True; r.font.color.rgb = VERT
p2 = tb.text_frame.add_paragraph()
r2 = p2.add_run(); r2.text = "Sécurité de l'application, conformité RGPD et mesures à décider"
r2.font.size = Pt(24); r2.font.color.rgb = NOIR
tb2 = s.shapes.add_textbox(Inches(1), Inches(4.6), Inches(11.3), Inches(1.2))
p3 = tb2.text_frame.paragraphs[0]
r3 = p3.add_run(); r3.text = "Présentation à la direction — [date] — [nom de l'établissement]"
r3.font.size = Pt(16); r3.font.color.rgb = GRIS

# ---- 2. L'essentiel -------------------------------------------------------
s = add_slide("L'essentiel en 6 points")
bullets(s, [
    (0, "Nous traitons des données très sensibles : coordonnées complètes des étudiants et de leurs parents (France / USA), TIN (identifiant fiscal américain), copies de passeports.", None),
    (0, "Le RGPD s'applique intégralement à ces traitements, y compris pour des personnes de nationalité américaine : l'établissement est établi dans l'UE.", None),
    (0, "La sécurité technique est déjà solide (chiffrement généralisé des données et documents, MFA, contrôles anti-brute-force) ; des renforcements ciblés sont engagés.", None),
    (0, "Deux chantiers relèvent de la direction : les durées de conservation des documents sensibles (passeports, TIN) et la formalisation RGPD (registre, information, PIA).", None),
    (0, "Sanctions possibles en cas de manquement : jusqu'à 20 M€ ou 4 % du chiffre d'affaires — mais le risque réel premier est la fraude d'identité touchant nos étudiants en cas d'incident.", ROUGE),
    (0, "Décisions attendues aujourd'hui : validation de la PIA, politique de conservation, migration vers un VPS.", VERT),
])

# ---- 3. Données traitées --------------------------------------------------
s = add_slide("Les données que nous traitons", "Inventaire et niveau de sensibilité")
bullets(s, [
    (0, "Étudiants américains — nom, prénom, mail, téléphone, adresses (France & USA), TIN.", ROUGE),
    (0, "Contacts des étudiants (parents) — mêmes coordonnées, côté USA.", None),
    (0, "Familles d'accueil et professeurs français — coordonnées professionnelles et personnelles.", None),
    (0, "Documents — passeports, attestations de scolarité, justificatifs de domicile.", ROUGE),
    (1, "Copie de passeport : régime CNIL strict — conservation courte uniquement si nécessaire.", None),
    (1, "TIN : identifiant fiscal → cible privilégiée de fraude d'identité ; accès restreint et journalisé.", None),
    (0, "Technique (non personnel) — journaux de connexion, IP, journaux d'erreurs.", GRIS),
    (0, "Toutes les données sensibles sont chiffrées en base et sur disque ; mails et IP restent lisibles pour l'authentification et l'anti-brute-force.", VERT),
])

# ---- 4. Cadre légal -------------------------------------------------------
s = add_slide("Cadre légal : pourquoi nous sommes concernés")
bullets(s, [
    (0, "RGPD art. 3 : s'applique dès que le responsable de traitement est établi dans l'UE — la nationalité des personnes concernées ne change rien.", None),
    (0, "Nous sommes « responsable de traitement » : nous choisissons les finalités et les moyens, peu importe qui héberge.", None),
    (0, "Pas forcément besoin d'un DPO nommé, mais obligations de base incontournables :", None),
    (1, "registre des traitements, information des personnes, sécurité (art. 32), notification d'incident à la CNIL sous 72 h.", None),
    (0, "La CNIL est notre autorité de contrôle ; sanctions jusqu'à 20 M€ ou 4 % du CA mondial, avec publication (mise en demeure) → risque d'image majeur.", None),
    (0, "Données de mineurs potentiels + identifiant fiscal → analyse d'impact (PIA) recommandée.", None),
])

# ---- 5. Obligations concrètes --------------------------------------------
s = add_slide("Nos obligations RGPD concrètes")
bullets(s, [
    (0, "Registre des traitements — « carte d'identité » de chaque traitement (finalité, données, durée, destinataires). Il se remplit en 1-2 demi-journées.", None),
    (0, "Information des 4 publics — étudiants, parents, familles d'accueil, professeurs : mention claire (finalités, conservation, droits, sous-traitants (hébergeur)).", None),
    (0, "Bases légales documentées — contrat (étudiants) / intérêt légitime (parents, familles d'accueil) ; consentement séparé si nécessaire.", None),
    (0, "PIA — analyse d'impact ciblée sur TIN + copies de passeports ; à valider par la direction.", None),
    (0, "Droits des personnes — procédure simple d'accès / rectification / suppression, avec délai d'un mois.", None),
    (0, "Sous-traitants — contrats avec l'hébergeur et tout CDN (clauses RGPD standard, souvent incluses).", None),
])

# ---- 6. Répartition des rôles --------------------------------------------
s = add_slide("Répartition des responsabilités")
two_columns(s,
    "Direction — décide et porte",
    [(0, "Finalités du traitement et bases légales", None),
     (0, "Durées de conservation et suppression (décisif)", None),
     (0, "Information des personnes + registre", None),
     (0, "Validation de la PIA", None),
     (0, "Budget hébergement (VPS) et outils", None),
     (0, "Politique de gestion d'incident (qui décide, qui notifie)", None)],
    "Informatique — réalise et rend compte",
    [(0, "Chiffrement base + documents, clés et rotation", None),
     (0, "MFA, anti-brute-force, journaux d'accès", None),
     (0, "Purges automatiques selon les durées votées", None),
     (0, "Sauvegardes testées, mises à jour, monitoring", None),
     (0, "Détection/protection (CrowdSec, WAF)", None),
     (0, "Traitement technique des incidents + alerte à la direction", None)])

# ---- 7. État actuel -------------------------------------------------------
s = add_slide("Sécurité déjà en place (état actuel)")
bullets(s, [
    (0, "Chiffrement de toutes les données sensibles en base (AES-256) ; déchiffrement uniquement à l'affichage pour les rôles autorisés.", VERT),
    (0, "Documents chiffrés sur le système de fichiers, stockés hors zone web.", VERT),
    (0, "MFA (login + IP), protection anti-brute-force basée sur l'adresse IP.", VERT),
    (0, "Mails et IP en clair — choix justifié (authentification + contrôle IP).", GRIS),
    (0, "Clé de chiffrement dans le fichier de configuration du serveur — standard actuel, renforcement en cours.", None),
    (0, "Analyse des logs et des tentatives d'attaque déjà réalisée (replay CrowdSec) → attack surface connue.", None),
])

# ---- 8. Renforcements engagés --------------------------------------------
s = add_slide("Renforcements techniques engagés / planifiés")
bullets(s, [
    (0, "Séparation des clés par type de données (session / base / documents).", None),
    (0, "Chiffrement « en enveloppe » des documents (clé par document) → rotation sans tout ré-encoder.", None),
    (0, "Procédure testée de rotation de clés.", None),
    (0, "Journal d'accès aux documents sensibles : qui a consulté quel passeport, quand.", None),
    (0, "Purge automatique des TIN et documents selon les durées validées par la direction.", None),
    (0, "Protection temps réel (CrowdSec) après migration VPS ; filtrage en amont (CDN/WAF) des sites publics.", None),
])

# ---- 9. Conservation ------------------------------------------------------
s = add_slide("Conservation & suppression — à arbitrer par la direction",
              "Le RGPD interdit de garder « au cas où » : chaque donnée a une durée max")
bullets(s, [
    (0, "Données de dossier (nom, coordonnées, historique) — durée de la relation + prescription (recommandé : 3 à 5 ans après le départ de l'étudiant).", None),
    (0, "TIN — uniquement le temps des obligations fiscales obligatoires ; suppression dès qu'elles s'achèvent.", ROUGE),
    (0, "Copie de passeport — le temps de vérification / du séjour uniquement ; jamais en archive permanente.", ROUGE),
    (0, "Justificatifs de domicile — temps du logement, puis suppression.", None),
    (0, "Moyens : tableau des durées voté + purge automatique + rapport annuel de conformité.", None),
    (0, "Point CNIL clé : les copies de pièces d'identité conservées sans justification sont un motif classique de sanction.", None),
])

# ---- 10. Hébergement ------------------------------------------------------
s = add_slide("Hébergement : recommandation de migration vers un VPS")
bullets(s, [
    (0, "Aujourd'hui (hébergement mutualisé) : pas de pare-feu, pas de blocage temps réel, clé de chiffrement forcée au même endroit que les données.", None),
    (0, "VPS (~10-15 €/mois) : protection temps réelle CrowdSec, isolation possible de la clé de chiffrement, filtrage en amont (Cloudflare/WAF UE), contrôle complet.", None),
    (0, "Migration planifiée : duplication, tests, bascule DNS — sans coupure de service.", None),
    (0, "Bénéfice sécurité principal : une compromission du serveur n'expose plus que des données chiffrées, la clé étant isolée.", VERT),
    (0, "Coût caché assumé : temps d'administration (estimé : 1-2 j/mois, en partie déjà consacré aujourd'hui).", GRIS),
])

# ---- 11. Plan d'action ----------------------------------------------------
s = add_slide("Plan d'action priorisé", "P1 = immédiat (ce trimestre)")
bullets(s, [
    (0, "P1 — Registre des traitements + mentions d'information (informatique + direction) : 2-3 jours.", VERT),
    (0, "P1 — Durées de conservation : tableau soumis au vote, purge automatique.", VERT),
    (0, "P1 — Durcissement .env / clés / APP_DEBUG (déjà engagé).", None),
    (0, "P2 — PIA sur TIN + passeports : ½ journée, validation direction.", None),
    (0, "P2 — Journal d'accès aux documents + enveloppe de chiffrement (1-2 jours de dev).", None),
    (0, "P3 — Migration VPS + protection temps réel (CrowdSec).", None),
    (0, "P4 — Procédure « droits des personnes » + exercice de gestion d'incident (test sur table).", None),
])

# ---- 12. Risques -----------------------------------------------------------
s = add_slide("Risques en cas d'inaction")
bullets(s, [
    (0, "Fraude d'identité touchant nos étudiants (TIN + passeport + adresses) → responsabilité de l'établissement, perte de confiance des partenaires américains.", ROUGE),
    (0, "Sanction CNIL : jusqu'à 20 M€ / 4 % du CA ; même une simple mise en demeure publiée nuit à l'image.", ROUGE),
    (0, "Obligation d'incident (72 h) impossible à honorer sans registre ni procédure.", None),
    (0, "Dépendance à un hébergement non maîtrisé : données inaccessibles en cas de panne ou de résiliation chez l'hébergeur.", None),
    (0, "Démonstration de sérieux attendue par les familles et l'école américaine (question fréquente des parents).", GRIS),
])

# ---- 13. Décisions demandées ----------------------------------------------
s = add_slide("Décisions demandées aujourd'hui")
bullets(s, [
    (0, "1. Valider le principe des durées de conservation proposées (slide 9) et la purge automatique.", VERT),
    (0, "2. Lancer le registre des traitements + les mentions d'information (informatique + direction).", VERT),
    (0, "3. Valider la réalisation de la PIA (TIN + passeports).", None),
    (0, "4. Autoriser la migration vers un VPS et son budget (~120-200 €/an + temps).", None),
    (0, "5. Désigner l'interlocuteur « incident » côté direction (notification CNIL 72 h).", None),
])

# ---- 14. Annexe -----------------------------------------------------------
s = add_slide("Annexes & prochaines étapes")
bullets(s, [
    (0, "Annexe A — tableau des données / finalités / durées (support du registre).", None),
    (0, "Annexe B — schéma de l'architecture de sécurité (chiffrement, clés, MFA, monitoring).", None),
    (0, "Annexe C — extraits d'analyse des attaques (top IP / scénarios observés sur nos logs).", None),
    (0, "Contact interne : [votre nom] — informaticien référent.", GRIS),
    (0, "Ressources : cnil.fr (registre, PIA), guides RGPD.", GRIS),
])

prs.save("docs/Protection_donnees_etudiants.pptx")
print("OK — slides:", len(prs.slides._sldIdLst))
