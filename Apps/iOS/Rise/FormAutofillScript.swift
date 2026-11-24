import WebKit

/// The page's half of Autofill My Information, in a world of its own so pages can neither see it
/// nor speak for it, in every frame, as checkouts often put their address forms in one.
///
/// It costs a page nothing until a field is focused, and then only a message: the script asks
/// whether autofill is on, and only if it is does it work out what the field is for (from its
/// `autocomplete`, its labels, its name and id, its placeholder, and the words beside it, in
/// several languages) and tell the app, which shows the keyboard bar's button when the card has
/// something for it. Filling is the app's: it asks the script to pick the way of writing the
/// value the field takes (its length, pattern and placeholder, a separate country code beside a
/// phone number) and to select what's there, types it in as the keyboard would, and then checks
/// it landed, setting it as the page's own script would where it didn't. Nothing of the card is
/// put into the page until a value is chosen, and only into the focused field.
@MainActor enum FormAutofillScript {
    static let world = WKContentWorld.world(name: "Rise.Autofill")
    static let messageName = "riseAutofill"
    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    private static let installed = NSHashTable<WKUserContentController>.weakObjects()

    /// Once for each set of pages' scripts: a page opened by another may share its opener's.
    static func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        guard !installed.contains(controller) else { return }
        installed.add(controller)
        controller.addUserScript(userScript)
        controller.addScriptMessageHandler(FormAutofillBridge.shared, contentWorld: world, name: messageName)
    }

    nonisolated static let source = #"""
    (() => {
      if (globalThis.__riseAutofill) return;
      const send = message => {
        try { return globalThis.webkit.messageHandlers.riseAutofill.postMessage(message); }
        catch { return Promise.resolve(false); }
      };
      const frame = Math.random().toString(36).slice(2, 10);
      let counter = 0, reported = '';
      const tokens = new WeakMap(), refs = new Map();
      const tokenOf = el => {
        let token = tokens.get(el);
        if (token) return token;
        token = frame + '.' + (++counter);
        tokens.set(el, token);
        if (refs.size > 64) for (const [key, ref] of refs) if (!ref.deref()?.isConnected) refs.delete(key);
        refs.set(token, new WeakRef(el));
        return token;
      };
      const deepActive = () => {
        let el = document.activeElement;
        while (el?.shadowRoot?.activeElement) el = el.shadowRoot.activeElement;
        return el;
      };
      const FIELD = new Set(['INPUT', 'TEXTAREA']);
      const SKIPPED = new Set(['hidden', 'password', 'checkbox', 'radio', 'file', 'submit', 'button', 'image', 'reset',
        'range', 'color', 'datetime-local', 'month', 'week', 'time']);

      // ——— Reading a field's words ———
      const normalise = (value, words = true) => {
        if (!value) return '';
        let text = String(value).slice(0, 200);
        // A label's own words, not its help text or the asterisk saying it's required.
        if (words) text = text.split(/\(|\[|\s[-–—|]\s|\.\s|\?\s|\n/)[0];
        text = text.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/([a-zA-Z])(\d)/g, '$1 $2');
        text = text.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
          .replace(/ł/g, 'l').replace(/ø/g, 'o').replace(/ß/g, 'ss').replace(/æ/g, 'ae').replace(/đ/g, 'd');
        return text.replace(/[_\-.:;,*'"’\[\]{}\/\\|#!?]+/g, ' ').replace(/\s+/g, ' ').trim();
      };
      const textOf = node => (node?.textContent || '').replace(/\s+/g, ' ').trim();
      const labelsOf = el => {
        const parts = [];
        try { for (const label of el.labels || []) parts.push(textOf(label)); } catch {}
        const aria = el.getAttribute('aria-label');
        if (aria) parts.push(aria);
        const root = el.getRootNode();
        for (const id of (el.getAttribute('aria-labelledby') || '').split(/\s+/)) {
          if (!id) continue;
          const node = root.getElementById ? root.getElementById(id) : document.getElementById(id);
          if (node && node !== el) parts.push(textOf(node));
        }
        // A web component's field takes its label from the component.
        if (root instanceof ShadowRoot) {
          for (const name of ['label', 'aria-label']) {
            const value = root.host.getAttribute(name);
            if (value) parts.push(value);
          }
        }
        return parts.filter(Boolean).join(' ');
      };
      const ATTRIBUTES = ['name', 'id', 'formcontrolname', 'data-testid', 'data-test', 'data-qa', 'data-field', 'data-name', 'ng-model'];
      const attributesOf = el => {
        const values = ATTRIBUTES.map(name => el.getAttribute(name)).filter(Boolean);
        const root = el.getRootNode();
        if (root instanceof ShadowRoot) for (const name of ['name', 'id']) {
          const value = root.host.getAttribute(name);
          if (value) values.push(value);
        }
        return values.join(' ');
      };
      const isField = node => node.matches?.('input:not([type=hidden]), select, textarea, button');
      // The words just before a field with no label of its own, as many forms put them: in the
      // same wrapper, before another field's words would be.
      const nearbyText = el => {
        let node = el;
        for (let depth = 0; depth < 4 && node && node !== document.body; depth++) {
          let sibling = node.previousElementSibling;
          for (let step = 0; sibling && step < 3; step++, sibling = sibling.previousElementSibling) {
            if (isField(sibling) || sibling.querySelector?.('input:not([type=hidden]), select, textarea')) return '';
            const text = textOf(sibling);
            if (text) return text.length <= 80 ? text : '';
          }
          if (depth === 0) {
            const after = node.nextElementSibling;
            if (after && /^(LABEL|SPAN|DIV|P)$/.test(after.tagName) && !after.querySelector('input, select, textarea')) {
              const text = textOf(after);
              if (text && text.length <= 40) return text;
            }
          }
          const parent = node.parentElement;
          if (!parent || parent.querySelectorAll('input:not([type=hidden]), select, textarea').length > 1) break;
          node = parent;
        }
        return '';
      };
      const groupText = el => {
        const group = el.closest('fieldset, [role=group], [role=radiogroup]');
        if (!group) return '';
        const legend = group.querySelector('legend');
        const labelled = group.getAttribute('aria-labelledby');
        return [legend && textOf(legend), group.getAttribute('aria-label'),
          labelled && labelled.split(/\s+/).map(id => textOf(document.getElementById(id))).join(' ')].filter(Boolean).join(' ').slice(0, 120);
      };

      // ——— What the words say ———
      const rx = source => new RegExp(source, 'u');
      const NOT_OURS = rx(String.raw`search|\bquery\b|keyword|coupon|promo|voucher|discount|gift ?card|captcha|\botp\b|one ?time|verification|\bverify|security ?(code|question|answer)|\bcvv|\bcvc|\bcsc\b|card ?(number|no\b|num\b)|credit ?card|debit|\biban\b|\bbic\b|swift|sort ?code|account ?(number|no\b)|routing|password|passcode|passwort|mot de passe|contrasena|haslo|\bpin\b(?! ?code)|expir|\bexp\b|valid ?(thru|through|until|from)|nationality|citizenship|place of birth|birth ?place|(city|country|town|state) of birth|birth (city|country|town|name)|message|comment|subject|feedback|question|enquiry|inquiry|\bnotes?\b|instruction|quantity|\bqty\b|amount|price|\bvat\b|\btax\b|\bnip\b|pesel|regon|\bssn\b|social security|passport|licen[cs]e|\bip\b|mac address|wallet|domain|tracking|invoice|order ?(number|no\b|id\b)|referr|wyszukaj|szukaj|\bsuche\b|recherche|buscar|\bcerca\b|rabat|gutschein|\bsms\b|\btoken\b|\bfriend|recipient s (email|phone)|emergency|next of kin|\bkin\b|mother s|father s|maiden`);
      const RULES = [
        ['url-linkedin', rx(String.raw`linked ?in`)],
        ['url-github', rx(String.raw`git ?hub`)],
        ['url-x', rx(String.raw`twitter|^x$|\bx (profile|handle|url|link|account)|\bx com\b`)],
        ['url', rx(String.raw`website|web ?site|homepage|home ?page|web ?address|portfolio|personal (site|page|url|link)|\bblog\b|^url$|\burl\b|^link$|profile (url|link)|strona (www|internetowa)|webseite|site web|sitio web`)],
        ['email', rx(String.raw`\be ?mail|email|courriel|correo|posta elettronica|\bepost|sahkoposti|eposta|\be ?post\b|elektroniczn|электрон|почта|メール|邮件|邮箱|電子郵件|電郵|이메일`)],
        ['tel-country-code', rx(String.raw`(dial(ing)?|calling|phone|tel(ephone)?|mobile|cell) ?(country ?)?(code|prefix)\b|country ?(dial(ing)?|calling) ?code|\bdial ?code|kierunkowy|indicatif|prefijo|prefisso|vorwahl|\bddi\b`)],
        [null, rx(String.raw`\bext\b|extension|durchwahl|wewnetrzny`)],
        ['tel', rx(String.raw`phone|mobile|\bcell|\bfax\b|telefon|telefono|telefone|telefoon|\btel\b|\btelf\b|portable|\bhandy\b|movil|cellulare|celular|telemovel|komork|\bgsm\b|whatsapp|contact (no|number)|телефон|мобильн|電話|电话|手机|携帯|전화|휴대폰|핸드폰`)],
        [null, rx(String.raw`user ?name|\blogin\b|user ?id\b|account ?name|screen ?name|\bhandle\b`)],
        ['name', rx(String.raw`full ?name|your ?name|complete ?name|\bname (and|&) surname|first (and|&) last|first ?last ?name|forename (and|&) surname|nombre completo|nombre y apellido|nom complet|nom et prenom|prenom et nom|vollstandiger name|vor ?und ?(nach|zu) ?name|nome completo|nome e cognome|imie i nazwisko|imie nazwisko|volledige naam|voor ?en ?achternaam|fuldt navn|fullstendig navn|fullstandigt namn|\bfio\b|фио|ф и о|氏名|お名前|姓名|성명|card ?holder|name on (the )?card|account ?holder|\bfullname\b`)],
        ['family-name', rx(String.raw`last ?name|family ?name|sur ?name|\blname\b|^last$|second ?name|nachname|familienname|zuname|apellido|nom de famille|cognome|nazwisko|achternaam|etternavn|efternavn|efternamn|sukunimi|prezime|prijmeni|vezeteknev|soyad|фамилия|苗字|^姓$`)],
        ['given-name', rx(String.raw`first ?name|given ?name|fore ?name|\bfname\b|^first$|vorname|prenom|\bimie\b|voornaam|fornavn|fornamn|etunimi|^ime$|jmeno|krestni|keresztnev|primer nombre|nombre de pila|primeiro nome|^имя$|^名$|^이름$`)],
        ['additional-name-initial', rx(String.raw`middle ?init(ial)?s?\b|^m ?i$|\bmid ?init`)],
        ['additional-name', rx(String.raw`middle ?(name|initial)|\bmname\b|^middle$|segundo nombre|drugie imie|zweiter vorname|отчество|patronymic`)],
        ['honorific-suffix', rx(String.raw`(name )?suffix\b`)],
        ['organization-title', rx(String.raw`job ?title|\bposition\b|occupation|profession|\brole\b|designation|stanowisko|\bzawod\b|\bberuf\b|\bposte\b|\bcargo\b|\bpuesto\b|funzione|должност|職`)],
        ['organization', rx(String.raw`(company|organi[sz]ation|business|employer|\bfirm\b|\bfirma\b|\bfirmen|empresa|societe|azienda|unternehmen|bedrijf|ragione sociale|workplace|place of work|компани|организац|会社|公司|회사)(?!.*\b(address|street|city|town|post|zip|country|size|type|website|industry|number|reg)\b)`)],
        ['address-line3', rx(String.raw`address ?(line)? ?(3|three)\b|\baddr ?3\b|street ?3\b|\bline ?3\b|third line`)],
        ['address-line2', rx(String.raw`address ?(line)? ?(2|two)\b|\baddr ?2\b|street ?2\b|\bline ?2\b|second line|apartment|\bapt\b|\bsuite\b|\bunit\b|\bflat\b|\bbldg\b|\bfloor\b|complement|adresszusatz|\bzusatz|appartement|\bpiso\b|\bdpto\b|departamento|numer (lokalu|mieszkania)|nr (lokalu|mieszkania)|\blokal\b|mieszkani|\binterior\b|care of|optional address|address continued`)],
        ['address-line1', rx(String.raw`address ?(line)? ?(1|one)\b|\baddr ?1\b|street ?1\b|\bline ?1\b|first line|house ?name|building ?name`)],
        ['street?', rx(String.raw`(strasse|street|ulica|calle|rue) ?(und|and|&|i|y|et)? ?(haus ?|house ?)?(nummer|number|numer|numero)|street ?address|strasse hausnummer|ulica i numer`)],
        ['house-number', rx(String.raw`(house|building|street|home) ?(no\b|nr\b|num|number)|hausnummer|hausnr|haus ?nr|numer (domu|budynku)|nr (domu|budynku)|numero civico|huisnummer|husnummer|^(no|nr|n|number|numero|nummer)$`)],
        ['address-level2', rx(String.raw`(?<!ethni|electri|capa|veloc|authenti|publi|simpli|atro|dupli|scar|elasti|toxi|specifi|domesti|authori|periodi|opa)city|\btown\b|suburb|locality|\bciudad|\bville\b|\bcommune\b|\bcitta|\bcomune\b|localita|\bstadt\b|\bort\b|wohnort|miasto|miejscowosc|\bplaats|woonplaats|\bcidade|municipio|poblacion|kommune|poststed|\bpostort|город|населенн|市区町村|城市|도시|post ?town`)],
        ['county', rx(String.raw`\bcounty\b|hrabstwo|\bpowiat\b|\bkreis\b`)],
        ['address-level1', rx(String.raw`(?<!united )\bstate\b|province|provincia|\bregion\b|wojewodztwo|bundesland|\bestado\b(?! civil)|prefecture|\bcanton\b|kanton|territor|область|регион|都道府県|^省`)],
        ['address-level3', rx(String.raw`\bdistrict\b|dzielnica|neighbou?rhood|\bbarrio\b|\bbairro\b|quartier|ortsteil|stadtteil|sublocality|\bcolonia\b`)],
        ['postal-code', rx(String.raw`\bzip|postal(?! ?address)|post ?code|\bpcode|pin ?code|postleitzahl|\bplz\b|code postal|codigo postal|\bcp\b|\bcap\b|\bcep\b|kod pocztowy|kodpocztowy|postnummer|postinumero|\bpostnr|iranyitoszam|\bpsc\b|почтовый индекс|индекс|郵便番号|邮政编码|邮编|郵遞區號|우편`)],
        ['country-code?', rx(String.raw`country ?code`)],
        ['country', rx(String.raw`country|countries|\bpais\b|\bland\b|\bkraj\b|\bpays\b|paese|nazione|страна|国家|국가|\bulke\b`)],
        ['street?', rx(String.raw`street|strasse|\bulica\b|\bul\b|\brue\b|\bcalle\b|\bvia\b|\bvej\b|gatan|\bgata\b|\bstraat\b|\brua\b|\broad\b|avenue|\bavenida\b`)],
        ['address?', rx(String.raw`address|\badres|adresse|indirizzo|direccion|endereco|morada|\badress|osoite|住所|地址|주소|адрес`)],
        ['nickname', rx(String.raw`nick ?name|display ?name|preferred ?name|pseudonim|spitzname|\bsurnom\b|\bapodo\b|soprannome`)],
        ['honorific-prefix', rx(String.raw`^(title|salutation|honorific|prefix|anrede|civilite|tratamiento|tytul|zwrot|form of address|titel)$|honorific|salutation`)],
        ['bday?', rx(String.raw`birth|\bbday\b|\bb day\b|\bdob\b|\bd o b\b|geburt|naissance|nacimiento|nascita|nascimento|urodzen|geboorte|fodsel|syntym|рожден|生年月日|出生|생년월일|생일`)],
        ['age', rx(String.raw`^(your )?age$|\bage\b|^wiek$|\balter\b|^edad$|^eta$|^idade$|^leeftijd$|возраст|年齢|나이`)],
        [null, rx(String.raw`(event|project|pet|team|group|product|file|store|shop|brand|business|company|org|organisation|organization|display|user|screen|nick|maiden|mother|father|parent|child|kid|baby|partner|spouse|emergency|friend|reference|referee|guest|venue|course|school|university|college|bank|hotel|device|list|board|item|recipe|playlist|room|server|app|site|page|folder|tag|label|category|role|plan|street|house|building|town|city|country|card|account|vehicle|campaign|workspace|repository|repo|channel|game|character|song|artist|book|wifi|network|beneficiary) ?name`)],
        ['name?', rx(String.raw`\bname\b|^(nom|nombre|nome|naam|navn|namn|nimi|ime|jmeno|nev|isim|имя|名前|이름)$`)],
      ];
      const CODE = /\bcode\b|\bpin\b|\bkod\b|\bcodigo\b|\bcodice\b/;
      // What the words decide: a kind, null for something not ours (a coupon), undefined for nothing.
      const match = text => {
        if (!text) return undefined;
        if (NOT_OURS.test(text)) return null;
        for (const [kind, pattern] of RULES) if (pattern.test(text)) return kind;
        return undefined;
      };
      // An example in the placeholder, where its words say nothing.
      const shapeOf = placeholder => {
        // "e.g. ada@example.com" as well as the example alone.
        const text = (placeholder || '').trim().replace(/^(e\.?\s?g\.?|eg|ex\.?|example|z\.?\s?b\.?|np\.?|p\.?\s?ex\.?|ej\.?)[:\s]+/i, '');
        if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(text)) return 'email';
        if (/^\+?\d[\d\s().-]{6,}\d$/.test(text)) return 'tel';
        if (/^[a-z]{1,2}\d[a-z\d]? ?\d[a-z]{2}$/i.test(text)) return 'postal-code';
        if (/^https?:\/\//i.test(text)) return 'url';
        return undefined;
      };

      const AUTOCOMPLETE = {
        'name': 'name', 'honorific-prefix': 'honorific-prefix', 'given-name': 'given-name', 'additional-name': 'additional-name',
        'additional-name-initial': 'additional-name-initial', 'middle-initial': 'additional-name-initial',
        'middleinitial': 'additional-name-initial',
        'family-name': 'family-name', 'honorific-suffix': 'honorific-suffix', 'nickname': 'nickname',
        'organization-title': 'organization-title', 'organization': 'organization', 'street-address': 'street-address',
        'address-line1': 'address-line1', 'address-line2': 'address-line2', 'address-line3': 'address-line3',
        'address-level3': 'address-level3', 'address-level2': 'address-level2', 'address-level1': 'address-level1',
        'country': 'country', 'country-name': 'country', 'postal-code': 'postal-code', 'bday': 'bday?', 'bday-day': 'bday-day',
        'bday-month': 'bday-month', 'bday-year': 'bday-year', 'tel': 'tel', 'tel-country-code': 'tel-country-code',
        'tel-national': 'tel-national', 'email': 'email', 'url': 'url',
        // Not the standard's, but what sites write.
        'fname': 'given-name', 'firstname': 'given-name', 'first-name': 'given-name', 'lname': 'family-name',
        'lastname': 'family-name', 'last-name': 'family-name', 'surname': 'family-name', 'fullname': 'name',
        'full-name': 'name', 'phone': 'tel', 'mobile': 'tel', 'telephone': 'tel', 'phone-number': 'tel', 'zip': 'postal-code',
        'zipcode': 'postal-code', 'zip-code': 'postal-code', 'postcode': 'postal-code', 'postal': 'postal-code',
        'city': 'address-level2', 'town': 'address-level2', 'state': 'address-level1', 'province': 'address-level1',
        'county': 'county', 'address': 'address?', 'street': 'street?', 'address1': 'address-line1', 'address2': 'address-line2',
        'company': 'organization', 'company-name': 'organization', 'job-title': 'organization-title', 'birthday': 'bday?',
        'dob': 'bday?', 'e-mail': 'email',
      };
      const NOT_OUR_AUTOCOMPLETE = /^(current-password|new-password|one-time-code|cc-.*|transaction-.*|photo|impp|sex|language|tel-extension|tel-area-code|tel-local.*|address-level4)$/;
      const fromAutocomplete = (el, type) => {
        const parts = (el.getAttribute('autocomplete') || '').toLowerCase().trim().split(/\s+/).filter(part => part && part !== 'webauthn');
        if (!parts.length) return undefined;
        const field = parts[parts.length - 1];
        if (field === 'on' || field === 'off') return undefined;
        if (parts.includes('fax') || parts.includes('pager')) return null;
        if (Object.hasOwn(AUTOCOMPLETE, field)) return AUTOCOMPLETE[field];
        if (field === 'username') return type === 'email' || fromWords(el, type) === 'email' ? 'email' : null;
        // Sites put a password's value on any field to keep browsers' own autofill away.
        if ((field === 'new-password' || field === 'current-password') && type !== 'password') return undefined;
        if (NOT_OUR_AUTOCOMPLETE.test(field)) return null;
        return undefined;
      };
      const fromWords = (el, type, light) => {
        const sources = [labelsOf(el), attributesOf(el), el.getAttribute('placeholder'), el.getAttribute('title')];
        if (!light) sources.push(nearbyText(el));
        const texts = sources.map((source, index) => normalise(source, index !== 1));
        for (const text of texts) {
          const kind = match(text);
          if (kind !== undefined) return kind;
        }
        const shape = shapeOf(el.getAttribute('placeholder'));
        if (shape) return shape;
        if (!light) {
          const group = normalise(groupText(el));
          if (group && RULES.find(([kind]) => kind === 'bday?')[1].test(group) && !NOT_OURS.test(group)) return 'bday?';
        }
        if (texts.some(text => CODE.test(text))) return null;
        if (type === 'email') return 'email';
        if (type === 'tel') return el.maxLength > 0 && el.maxLength < 6 ? null : 'tel';
        if (type === 'url') return 'url';
        return undefined;
      };

      // ——— A field's neighbours ———
      const FIELDS = 'input:not([type=hidden]):not([type=submit]):not([type=button]):not([type=checkbox]):not([type=radio]):not([type=image]):not([type=reset]):not([type=file]), select, textarea';
      const visible = el => el.offsetWidth > 0 || el.offsetHeight > 0 || el.getClientRects().length > 0;
      const scopeOf = el => {
        let fields = null;
        if (el.form) fields = el.form.querySelectorAll(FIELDS);
        else {
          for (let node = el.parentElement, depth = 0; node && depth < 10; node = node.parentElement, depth++) {
            const found = node.querySelectorAll(FIELDS);
            if (found.length >= 4 || !node.parentElement) { fields = found; break; }
          }
        }
        return Array.from(fields || [el]).slice(0, 80).filter(field => field === el || visible(field));
      };
      const kindsNear = el => {
        const kinds = new Set();
        for (const field of scopeOf(el)) {
          if (field === el) continue;
          const kind = classify(field, true)?.kind;
          if (kind) kinds.add(kind);
        }
        return kinds;
      };
      const previousField = el => {
        const fields = scopeOf(el), index = fields.indexOf(el);
        return index > 0 ? fields[index - 1] : null;
      };
      const nextField = el => {
        const fields = scopeOf(el), index = fields.indexOf(el);
        return index >= 0 ? fields[index + 1] : null;
      };
      // A country code the page asks for apart from the number, so the number goes without one.
      const hasDialCode = el => {
        if (el.closest('.iti')) return !!el.closest('.iti--separate-dial-code, .iti--show-selected-dial-code');
        if (el.closest('.PhoneInput, .react-tel-input, .vue-tel-input')) return false;
        if (/^\+\s?\d{1,4}$/.test(nearbyText(el))) return true;
        const previous = previousField(el);
        if (!previous) return false;
        if (previous.tagName === 'SELECT') {
          const options = Array.from(previous.options).slice(0, 15);
          if (options.filter(option => /\+\s?\d{1,4}\b/.test(option.text + ' ' + option.value)).length >= 2) return true;
        }
        const kind = classify(previous, true)?.kind;
        return kind === 'tel-country-code' || kind === 'country-code?';
      };
      const birthdayPart = el => {
        if (el.type === 'date') return 'bday';
        const own = [normalise(labelsOf(el)), normalise(attributesOf(el), false), normalise(el.getAttribute('placeholder')), normalise(nearbyText(el))].join(' ');
        const year = /\b(year|yyyy|yy|y|jahr|annee|ano|anno|rok|rrrr|aaaa|jjjj)\b/.test(own);
        const month = /\b(month|mm|m|monat|mois|mes|mese|miesiac)\b/.test(own);
        const day = /\b(day|dd|d|tag|tt|jour|jj|dia|giorno|gg|dzien)\b/.test(own);
        if (year + month + day === 1) return year ? 'bday-year' : month ? 'bday-month' : 'bday-day';
        if (year + month + day > 1) return 'bday';
        if (el.maxLength === 4) return 'bday-year';
        return 'bday';
      };
      const resolve = (el, kind, type) => {
        const field = { kind };
        if (kind.endsWith('?')) {
          const near = kind === 'bday?' ? null : kindsNear(el);
          const has = name => near.has(name);
          if (kind === 'name?') {
            field.kind = has('family-name') && !has('given-name') ? 'given-name'
              : has('given-name') && !has('family-name') ? 'family-name' : 'name';
          } else if (kind === 'street?') {
            field.kind = has('house-number') ? 'street-name' : has('address-line2') ? 'address-line1' : 'street-address';
          } else if (kind === 'address?') {
            const elsewhere = has('address-level2') || has('postal-code') || has('address-line1') || has('street?');
            field.kind = !elsewhere ? 'address-full' : has('address-line2') ? 'address-line1' : 'street-address';
          } else if (kind === 'country-code?') {
            const next = nextField(el);
            field.kind = next && (next.type === 'tel' || classify(next, true)?.kind === 'tel') ? 'tel-country-code' : 'country';
          } else if (kind === 'bday?') {
            field.kind = birthdayPart(el);
          }
        }
        if (field.kind === 'tel') field.national = hasDialCode(el);
        // A middle name's field with room for only its initial.
        if (field.kind === 'additional-name' && el.maxLength > 0 && el.maxLength <= 2) field.kind = 'additional-name-initial';
        if (type === 'textarea' && !/^(street-address|address-full)$/.test(field.kind)) return null;
        if (type === 'date' && field.kind !== 'bday') return null;
        return field;
      };
      const classify = (el, light = false) => {
        if (light ? !(FIELD.has(el.tagName) || el.tagName === 'SELECT') : !FIELD.has(el.tagName)) return null;
        if (el.disabled || (el.readOnly && !light)) return null;
        const type = el.tagName === 'TEXTAREA' ? 'textarea' : el.tagName === 'SELECT' ? 'select' : (el.getAttribute('type') || 'text').toLowerCase();
        if (SKIPPED.has(type)) return null;
        const explicit = fromAutocomplete(el, type);
        const kind = explicit === undefined ? fromWords(el, type, light) : explicit;
        if (!kind) return null;
        // A site's own search box only when it says it's for an address.
        if (type === 'search' && explicit === undefined) return null;
        if (type === 'url' && !kind.startsWith('url')) return null;
        return light ? { kind } : resolve(el, kind, type);
      };
      // Which of the person's numbers or addresses a field asks for: "Work telephone", "Home email".
      const hintOf = el => {
        const text = [normalise(labelsOf(el)), normalise(attributesOf(el), false), normalise(el.getAttribute('placeholder'))].join(' ');
        if (/\b(fax|telefax)\b/.test(text)) return 'fax';
        if (/\b(mobile|cell|cellular|handy|mobil|mobiel|portable|gsm|movil|cellulare|komorkowy|komorka)\b/.test(text)) return 'mobile';
        if (/\b(work|office|business|daytime|corporate|company|dienstlich|geschaftlich|travail|trabajo|lavoro|sluzbowy)\b/.test(text)) return 'work';
        if (/\b(home|evening|private|personal|landline|privat|domicile|casa|domowy|prywatny)\b/.test(text)) return 'home';
        return undefined;
      };
      const describe = el => {
        const field = classify(el);
        if (!field) return null;
        return {
          hint: /^(tel|tel-national|email)$/.test(field.kind) ? hintOf(el) : undefined,
          kind: field.kind, national: !!field.national, multiline: el.tagName === 'TEXTAREA',
          value: String(el.value ?? '').slice(0, 300), maxLength: el.maxLength > 0 ? el.maxLength : 0,
          lang: (document.documentElement.lang || navigator.language || '').slice(0, 16),
        };
      };

      // ——— Filling ———
      const find = (token, kind) => {
        const el = refs.get(token)?.deref(), active = deepActive();
        if (el && el === active) return el;
        // The page swapped the field for another as it was focused, as some frameworks do.
        if (active && FIELD.has(active.tagName) && classify(active)?.kind === kind) return active;
        return null;
      };
      const rank = (variants, order) => {
        const position = variant => {
          const index = order.findIndex(tag => variant.t.includes(tag));
          return index < 0 ? order.length : index;
        };
        return variants.map((variant, index) => [variant, index])
          .sort((a, b) => position(a[0]) - position(b[0]) || a[1] - b[1]).map(([variant]) => variant);
      };
      const formatDate = (el, iso) => {
        if (el.type === 'date') return iso;
        const [year, month, day] = iso.split('-');
        const placeholder = (el.getAttribute('placeholder') || '').toLowerCase().trim();
        const shape = placeholder.match(/^([a-z]+)([^a-z0-9]+)([a-z]+)\2([a-z]+)$/) || placeholder.match(/^([a-z]{1,4})()([a-z]{1,4})()([a-z]{1,4})$/);
        let order = null, separator = '/', short = false;
        if (shape) {
          const parts = [shape[1], shape[3], shape[4]].map(part => /^(y+|a{4}|r{4}|j{4})$/.test(part) ? 'y' : /^m+$/.test(part) ? 'm' : 'd');
          if (new Set(parts).size === 3) {
            order = parts; separator = shape[2];
            short = [shape[1], shape[3], shape[4]][parts.indexOf('y')].length === 2;
          }
        }
        if (!order) {
          const lang = (document.documentElement.lang || navigator.language || '').toLowerCase();
          if (/^en-(us|ph)$|^en$/.test(lang) && navigator.language.toLowerCase() === 'en-us') order = ['m', 'd', 'y'];
          else if (/^(ja|zh|ko|hu|lt|sv|en-ca|fr-ca)/.test(lang)) { order = ['y', 'm', 'd']; separator = '-'; }
          else if (/^(de|pl|ru|cs|sk|fi|nb|no|da|tr|uk|ro|hr|sl|sr|et|lv|bg|be|kk)/.test(lang)) { order = ['d', 'm', 'y']; separator = '.'; }
          else order = ['d', 'm', 'y'];
          if (el.maxLength === 8 || el.maxLength === 6) { separator = ''; short = el.maxLength === 6; }
        }
        const values = { y: short ? year.slice(-2) : year, m: month, d: day };
        return order.map(part => values[part]).join(separator);
      };
      const pick = (el, kind, variants, national) => {
        if (kind === 'bday') return formatDate(el, variants[0].v);
        let list = variants;
        if (kind === 'tel' || kind === 'tel-national') {
          const placeholder = (el.getAttribute('placeholder') || '').trim();
          const order = national ? ['nsn', 'national', 'intl']
            : kind === 'tel-national' ? ['national', 'nsn']
            : /^(\+|00)/.test(placeholder) ? ['intl']
            : /^[0(]/.test(placeholder) ? ['national']
            : /^[1-9]/.test(placeholder) ? ['nsn'] : [];
          list = rank(list, order);
        }
        if (el.type === 'url') list = rank(list, ['https']);
        const max = el.maxLength > 0 ? el.maxLength : Infinity;
        let pattern = null;
        if (el.pattern) for (const flags of ['v', 'u']) {
          try { pattern = new RegExp('^(?:' + el.pattern + ')$', flags); break; } catch {}
        }
        const digits = el.type === 'number' || /^(numeric|decimal)$/.test(el.inputMode);
        const fits = value => value.length <= max && (!pattern || pattern.test(value));
        const chosen = list.find(variant => fits(variant.v) && (!digits || /^\d+$/.test(variant.v)))
          ?? list.find(variant => fits(variant.v)) ?? list.find(variant => variant.v.length <= max) ?? list[0];
        const value = chosen.v;
        return digits && !/^\d+$/.test(value) ? value.replace(/\D/g, '') : value;
      };
      const set = (el, value) => {
        const prototype = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
        if (setter) setter.call(el, value); else el.value = value;
        el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertReplacementText', data: value }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      };
      // Picks how to write it and selects what's there for it to replace; the app types it.
      const prepare = (token, kind, variants, national) => {
        const el = find(token, kind);
        if (!el || !variants?.length) return null;
        const value = pick(el, kind, variants, national);
        const before = String(el.value ?? '');
        if (before === value) return { done: true, before, value };
        if (el.type === 'date') { set(el, value); return { done: true, before, value: String(el.value) }; }
        if (before) {
          try { el.select(); } catch {}
          try { if (el.selectionStart !== 0 || el.selectionEnd !== before.length) el.setSelectionRange(0, before.length); } catch {}
        }
        return { text: value, before };
      };
      // What was typed landed, perhaps as the page formats it; where it didn't, it's put in as the
      // editor would, then as the page's own script would. Gives what the field holds now.
      const verify = (token, kind, text, before) => {
        const el = find(token, kind) || refs.get(token)?.deref();
        if (!el) return null;
        const now = () => String(el.value ?? '');
        const appended = () => before && text && now() === before + text;
        if (now() !== before && !appended()) return now();
        try {
          if (deepActive() === el) {
            el.select();
            if (document.execCommand(text ? 'insertText' : 'delete', false, text) && now() !== before && !appended()) return now();
          }
        } catch {}
        set(el, text);
        return now();
      };
      // Selects what was filled, for Undo to replace with what was there, unless it's since been changed.
      const prepareUndo = (token, kind, filled) => {
        const el = find(token, kind);
        if (!el || String(el.value ?? '') !== filled) return false;
        if (el.type === 'date') return true;
        try { el.select(); } catch {}
        try { if (el.selectionStart !== 0 || el.selectionEnd !== filled.length) el.setSelectionRange(0, filled.length); } catch {}
        return true;
      };

      addEventListener('focusin', event => {
        const el = event.composedPath?.()[0] ?? event.target;
        if (!(el instanceof Element)) return;
        if (!FIELD.has(el.tagName)) {
          if (reported) { reported = ''; send({ t: '' }); }
          return;
        }
        const token = tokenOf(el);
        reported = token;
        send({ t: token }).then(active => {
          if (active && reported === token && deepActive() === el) send({ t: token, f: describe(el) });
        }, () => {});
      }, true);

      Object.defineProperty(globalThis, '__riseAutofill', {
        value: Object.freeze({ prepare, verify, prepareUndo, set, describe: el => describe(el), classify: el => classify(el), tokenOf }),
      });
    })();
    """#
}

/// Routes each page's messages to its own `FormAutofill`.
@MainActor final class FormAutofillBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = FormAutofillBridge()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let webView = message.webView as? RiseWebView, let body = message.body as? [String: Any],
              let token = body["t"] as? String else { return replyHandler(false, nil) }
        let autofill = webView.autofill
        if token.isEmpty {
            autofill.blurred()
            replyHandler(false, nil)
        } else if body.keys.contains("f") {
            autofill.described(token: token, field: body["f"] as? [String: Any])
            replyHandler(true, nil)
        } else {
            replyHandler(autofill.focused(token: token, frame: message.frameInfo), nil)
        }
    }
}

/// A page's autofill: the field focused, what the card has for it, and filling it in.
@MainActor final class FormAutofill {
    struct Field: Equatable {
        var kind: String
        var national: Bool
        var multiline: Bool
        var value: String
        var maxLength: Int
        var language: String?
        /// Which of several the field asks for, by their labels: "home", "work", "mobile" or "fax".
        var hint: String? = nil
    }

    private weak var webView: RiseWebView?
    private let store: AutofillStore
    private var token: String?
    private var frame: WKFrameInfo?
    private(set) var field: Field?
    /// Everything the card has for the focused field, and what the bar's button offers of it: not
    /// what's already there.
    private var allChoices: [AutofillChoice] = []
    private(set) var choices: [AutofillChoice] = []
    /// What a fill replaced and put in, for Undo, while the field it filled is focused. Shared with
    /// the fill as it lands, so an Undo tapped meanwhile sees what it put in.
    private final class Filled {
        let token: String
        let kind: String
        var before = ""
        var after: String?
        init(token: String, kind: String) { self.token = token; self.kind = kind }
    }
    private var filled: Filled?
    var canUndo: Bool { filled.map { $0.token == token } ?? false }
    /// Fills and undos in turn, so an Undo tapped as a fill lands waits for it.
    private var work: Task<Void, Never>?
    /// The card's address picked last, offered first for the rest of the form.
    private var lastAddress: Int?
    /// The bar's button, told when what it offers changes.
    weak var button: FormAccessoryAutofill?

    init(webView: RiseWebView, store: AutofillStore = .shared) {
        self.webView = webView
        self.store = store
    }

    /// A field was focused: until the page says what it's for, there's nothing to offer.
    func focused(token: String, frame: WKFrameInfo) -> Bool {
        self.token = token
        self.frame = frame
        field = nil
        filled = nil
        allChoices = []
        update([], always: true)
        return store.isActive
    }

    func blurred() {
        token = nil; frame = nil; field = nil; filled = nil
        allChoices = []
        update([], always: true)
    }

    func described(token: String, field description: [String: Any]?) {
        guard token == self.token else { return }
        guard let description, let kind = description["kind"] as? String, AutofillValues.kinds.contains(kind),
              let profile = store.isEnabled ? store.profile : nil else { field = nil; return update([]) }
        let field = Field(kind: kind, national: description["national"] as? Bool ?? false,
                          multiline: description["multiline"] as? Bool ?? false,
                          value: (description["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                          maxLength: (description["maxLength"] as? NSNumber)?.intValue ?? 0,
                          language: (description["lang"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                          hint: description["hint"] as? String)
        self.field = field
        allChoices = AutofillValues.choices(for: kind, in: profile, multiline: field.multiline, language: field.language)
        update(Self.offered(allChoices, for: field, lastAddress: lastAddress))
    }

    /// What's worth offering: not what the field already holds, nor what can't fit it, and the
    /// address picked last first.
    static func offered(_ choices: [AutofillChoice], for field: Field, lastAddress: Int?) -> [AutofillChoice] {
        let normalised = { (value: String) in value.lowercased().filter { !$0.isWhitespace } }
        let current = normalised(field.value)
        var offered = choices.filter { choice in
            current.isEmpty || !choice.variants.contains { normalised($0.value) == current }
        }
        // Cut short, these would be wrong rather than shorter.
        let exact: Set<String> = ["email", "tel", "tel-national", "tel-country-code", "postal-code", "bday-day", "bday-month",
                                  "bday-year", "age", "url", "url-linkedin", "url-github", "url-x", "house-number"]
        if field.maxLength > 0, exact.contains(field.kind) {
            offered = offered.filter { $0.variants.contains { $0.value.count <= field.maxLength } }
        }
        // "Work telephone" gets the work number, where there is one, and "Fax" only a fax.
        if let hint = field.hint, ["tel", "tel-national", "email"].contains(field.kind) {
            let matching = offered.filter { Self.label($0.subtitle ?? "", matches: hint) }
            if !matching.isEmpty { offered = matching }
            else if hint == "fax" { offered = [] }
        }
        if let lastAddress, let index = offered.firstIndex(where: { $0.address == lastAddress }), index > 0 {
            offered.insert(offered.remove(at: index), at: 0)
        }
        return offered
    }

    /// Whether a number's or address's label is the kind a field asks for.
    static func label(_ label: String, matches hint: String) -> Bool {
        let label = label.lowercased()
        if label.contains("fax") { return hint == "fax" }
        return switch hint {
        case "mobile": ["mobile", "iphone", "cell"].contains { label.contains($0) }
        case "work": label.contains("work")
        case "home": label.contains("home")
        default: false
        }
    }

    private func update(_ choices: [AutofillChoice], always: Bool = false) {
        guard always || choices != self.choices else { return }
        self.choices = choices
        button?.refresh()
    }

    /// Fills the focused field with `choice`, written as the field takes it; the button turns to Undo.
    func fill(_ choice: AutofillChoice) {
        guard let webView, let token, let frame, let field, !canUndo else { return }
        if let address = choice.address { lastAddress = address }
        let record = Filled(token: token, kind: field.kind)
        filled = record
        button?.refresh()
        let variants = choice.variants.map { ["v": $0.value, "t": $0.tags] as [String: Any] }
        let arguments: [String: Any] = ["token": token, "kind": field.kind, "variants": variants, "national": field.national]
        let previous = work
        work = Task { [weak self, weak webView] in
            await previous?.value
            guard let webView else { return }
            let prepared = try? await webView.callAsyncJavaScript(
                "return globalThis.__riseAutofill?.prepare(token, kind, variants, national) ?? null",
                arguments: arguments, in: frame, contentWorld: FormAutofillScript.world) as? [String: Any]
            guard let prepared else { self?.forget(record); return }
            let before = prepared["before"] as? String ?? ""
            var after = prepared["value"] as? String
            if prepared["done"] as? Bool != true, let text = prepared["text"] as? String {
                // As the keyboard types: the page's editor, its input events, its undo.
                webView.insertAtCaret(text)
                after = try? await webView.callAsyncJavaScript(
                    "return globalThis.__riseAutofill?.verify(token, kind, text, before) ?? null",
                    arguments: ["token": token, "kind": field.kind, "text": text, "before": before],
                    in: frame, contentWorld: FormAutofillScript.world) as? String
            }
            if let after, after != before { record.before = before; record.after = after }
            else { self?.forget(record) }
        }
    }

    /// Puts back what the field had before it was filled, unless it's since been changed, and
    /// offers the card's values again.
    func undo() {
        guard let webView, let frame, var field, let filled, filled.token == token else { return }
        self.filled = nil
        field.value = filled.before.trimmingCharacters(in: .whitespacesAndNewlines)
        self.field = field
        update(Self.offered(allChoices, for: field, lastAddress: lastAddress), always: true)
        let previous = work
        work = Task { [weak webView] in
            await previous?.value
            // The fill's still landing, or never did: what it'll put back is what it found.
            guard let webView, let after = filled.after else { return }
            let arguments: [String: Any] = ["token": filled.token, "kind": filled.kind, "filled": after]
            guard (try? await webView.callAsyncJavaScript(
                "return globalThis.__riseAutofill?.prepareUndo(token, kind, filled) ?? false",
                arguments: arguments, in: frame, contentWorld: FormAutofillScript.world) as? Bool) == true else { return }
            if filled.before.isEmpty { webView.deleteAtCaret() } else { webView.insertAtCaret(filled.before) }
            _ = try? await webView.callAsyncJavaScript(
                "return globalThis.__riseAutofill?.verify(token, kind, text, before) ?? null",
                arguments: ["token": filled.token, "kind": filled.kind, "text": filled.before, "before": after],
                in: frame, contentWorld: FormAutofillScript.world)
        }
    }

    /// A fill that didn't happen leaves nothing to undo.
    private func forget(_ record: Filled) {
        guard filled === record else { return }
        filled = nil
        button?.refresh()
    }
}

extension RiseWebView {
    /// Types `text` into the focused field at its caret, replacing what's selected, as the keyboard does.
    @discardableResult func insertAtCaret(_ text: String) -> Bool {
        let insert = NSSelectorFromString("insertText:")
        guard let input = focusedInput(in: self), input.responds(to: insert) else { return false }
        input.perform(insert, with: text)
        return true
    }

    /// Deletes what's selected in the focused field, as the keyboard's delete key does.
    @discardableResult func deleteAtCaret() -> Bool {
        let delete = NSSelectorFromString("deleteBackward")
        guard let input = focusedInput(in: self), input.responds(to: delete) else { return false }
        input.perform(delete)
        return true
    }

    private func focusedInput(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews { if let found = focusedInput(in: subview) { return found } }
        return nil
    }
}
