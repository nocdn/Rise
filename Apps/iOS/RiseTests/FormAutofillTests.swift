import Contacts
import XCTest
import UIKit
import WebKit
@testable import RiseiOS

/// Autofill My Information: what the page script makes of real forms' fields, the card's values in
/// each way a field might want them, and a fill and its Undo through the page. Every detail here
/// is made up.
final class FormAutofillTests: XCTestCase {
    @MainActor private func page(_ html: String) async throws -> (RiseWebView, UIWindow) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let page = try XCTUnwrap(BrowserViewController.makeWebView(dataStore: .nonPersistent()) as? RiseWebView)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        page.frame = window.bounds; window.rootViewController?.view.addSubview(page)
        page.loadHTMLString("<!doctype html><meta name=viewport content='width=device-width'>"+html, baseURL: URL(string: "https://shop.example/"))
        for _ in 0..<250 where (try? await page.evaluateJavaScript("document.readyState")) as? String != "complete" {
            try await Task.sleep(for: .milliseconds(20))
        }
        return (page, window)
    }

    private static var profile: AutofillProfile {
        var profile = AutofillProfile()
        profile.givenName = "Ada"; profile.familyName = "Lovelace"; profile.middleName = "Augusta"
        profile.organization = "Analytical Engines"; profile.jobTitle = "Engineer"
        profile.emails = [.init(label: "Home", value: "ada@example.com"), .init(label: "Work", value: "ada@engines.example"),
                          .init(label: "Home", value: "ada.l@example.org")]
        profile.urls = [.init(label: "LinkedIn", value: "http://linkedin.com/in/ada-example"),
                        .init(label: "GitHub", value: "http://github.com/ada-example")]
        profile.phones = [.init(label: "Mobile", number: "+44 7700 900123", region: "gb")]
        profile.addresses = [.init(label: "Home", street: "12 Example Avenue\nLittle Testing", subLocality: "", city: "Chelmsford",
                                   subAdministrativeArea: "", state: "Essex", postalCode: "CM1 1AA",
                                   country: "United Kingdom", isoCountryCode: "gb")]
        profile.birthday = .init(day: 7, month: 3, year: 1990)
        return profile
    }

    // MARK: What fields are for

    static let forms = #"""
    <form id=uk>
      <label for=a1>First name</label><input id=a1 data-expect=given-name>
      <label for=a2>Last name *</label><input id=a2 data-expect=family-name>
      <label for=a3>Email address</label><input id=a3 type=email data-expect=email>
      <label for=a4>Phone number</label><input id=a4 type=tel data-expect=tel>
      <label for=a5>Address line 1</label><input id=a5 data-expect=address-line1>
      <label for=a6>Address line 2 (optional)</label><input id=a6 data-expect=address-line2>
      <label for=a7>Town/City</label><input id=a7 data-expect=address-level2>
      <label for=a8>County (optional)</label><input id=a8 data-expect=county>
      <label for=a9>Postcode</label><input id=a9 data-expect=postal-code>
      <label for=a10>Country</label><input id=a10 data-expect=country>
      <label for=a11>Company name</label><input id=a11 data-expect=organization>
      <label for=a12>Discount code</label><input id=a12 data-expect=none>
      <label for=a13>Delivery instructions</label><textarea id=a13 data-expect=none></textarea>
    </form>
    <form id=explicit>
      <input autocomplete="shipping given-name" aria-label="Field 1" data-expect=given-name>
      <input autocomplete="billing street-address" data-expect=street-address>
      <input autocomplete="off" name=email data-expect=email>
      <input autocomplete="new-password" name=street data-expect=street-address>
      <input autocomplete="one-time-code" type=tel data-expect=none>
      <input autocomplete=username type=email data-expect=email>
      <input autocomplete=username name=login data-expect=none>
      <input type=password name=email data-expect=none>
      <input autocomplete=tel-national data-expect=tel-national>
      <input autocomplete=bday type=date data-expect=bday>
      <input autocomplete="work tel" data-expect=tel>
      <input autocomplete="fax tel" data-expect=none>
      <input autocomplete="cc-name" name=name data-expect=none>
      <input autocomplete="nope-random" name=postcode data-expect=postal-code>
    </form>
    <form id=names>
      <input name="billing[first_name]" data-expect=given-name>
      <input name="customerLastName" data-expect=family-name>
      <input name="checkout_shipping_address_first_name" data-expect=given-name>
      <input name="postalCode" data-expect=postal-code>
      <input name="addressLine2" data-expect=address-line2>
      <input name="ctl00$Main$txtCity" data-expect=address-level2>
      <input name="user_email" data-expect=email>
      <input name="ethnicity" data-expect=none>
      <input name="coupon" data-expect=none>
      <input name="q" type=search data-expect=none>
      <input formcontrolname="phoneNumber" data-expect=tel>
    </form>
    <form id=name-surname><label>Name <input data-expect=given-name></label><label>Surname <input data-expect=family-name></label></form>
    <form id=contact>
      <label>Name <input data-expect=name></label><label>Email <input data-expect=email></label>
      <label>Message <textarea data-expect=none></textarea></label>
    </form>
    <form id=french>
      <label for=c1>Nom</label><input id=c1 data-expect=family-name>
      <label for=c2>Prénom</label><input id=c2 data-expect=given-name>
      <label for=c3>Code postal</label><input id=c3 data-expect=postal-code>
      <label for=c4>Ville</label><input id=c4 data-expect=address-level2>
      <label for=c5>Adresse e-mail</label><input id=c5 data-expect=email>
      <label for=c6>Téléphone portable</label><input id=c6 data-expect=tel>
    </form>
    <form id=polish>
      <label>Imię <input data-expect=given-name></label><label>Nazwisko <input data-expect=family-name></label>
      <label>Ulica i numer <input data-expect=street-address></label><label>Kod pocztowy <input data-expect=postal-code></label>
      <label>Miejscowość <input data-expect=address-level2></label><label>Numer telefonu <input data-expect=tel></label>
      <label>Adres e-mail <input data-expect=email></label><label>Województwo <input data-expect=address-level1></label>
    </form>
    <form id=german>
      <label>Vorname <input data-expect=given-name></label><label>Nachname <input data-expect=family-name></label>
      <label>Straße <input data-expect=street-name></label><label>Hausnummer <input data-expect=house-number></label>
      <label>PLZ <input data-expect=postal-code></label><label>Ort <input data-expect=address-level2></label>
      <label>Firma <input data-expect=organization></label>
    </form>
    <form id=spanish>
      <label>Nombre <input data-expect=given-name></label><label>Apellidos <input data-expect=family-name></label>
      <label>Correo electrónico <input data-expect=email></label><label>Teléfono móvil <input data-expect=tel></label>
    </form>
    <div id=unlabelled>
      <div><span>Email</span><input data-expect=email></div>
      <div><div>Full name</div><div><input data-expect=name></div></div>
      <div><p>Postcode</p><input data-expect=postal-code></div>
      <div><span>Card number</span><input data-expect=none></div>
    </div>
    <form id=placeholders>
      <input placeholder="you@example.com" data-expect=email>
      <input placeholder="First name" data-expect=given-name>
      <input placeholder="Last name" data-expect=family-name>
      <input type=tel placeholder="Enter code" data-expect=none>
      <input type=search placeholder="Search" data-expect=none>
      <input placeholder="SW1A 1AA" data-expect=postal-code>
    </form>
    <form id=dial>
      <label>Country code <select><option>+44</option><option>+48</option><option>+1</option></select></label>
      <label>Mobile <input type=tel data-expect=tel data-national=true></label>
    </form>
    <form id=plain-phone><label>Mobile <input type=tel data-expect=tel data-national=false></label><label>Email <input></label></form>
    <form id=prefix-phone><div class=row><span>+44</span><input type=tel name=phone data-expect=tel data-national=true></div></form>
    <form id=birthday>
      <fieldset><legend>Date of birth</legend>
        <label>Day <input data-expect=bday-day></label><label>Month <input data-expect=bday-month></label><label>Year <input data-expect=bday-year></label>
      </fieldset>
      <label>Date of birth <input placeholder="DD/MM/YYYY" data-expect=bday></label>
      <label>Age <input type=number data-expect=age></label>
      <label>Place of birth <input data-expect=none></label>
      <label>Job title <input data-expect=organization-title></label>
      <label>LinkedIn profile <input type=url data-expect=url-linkedin></label>
      <label>GitHub <input data-expect=url-github></label>
      <label>Website <input type=url data-expect=url></label>
      <label>Appointment date <input type=date data-expect=none></label>
    </form>
    <form id=one-address><label>Address <textarea data-expect=address-full></textarea></label><label>Name<input data-expect=name></label></form>
    <form id=us>
      <label>Street address <input data-expect=address-line1></label>
      <label>Apartment, suite, etc. <input data-expect=address-line2></label>
      <label>City <input data-expect=address-level2></label><label>State <input data-expect=address-level1></label>
      <label>ZIP code <input data-expect=postal-code></label>
    </form>
    <form id=login>
      <label>Email or username <input data-expect=email></label><label>Username <input data-expect=none></label>
      <label>Password <input type=password data-expect=none></label>
    </form>
    <form id=codes>
      <label>Phone (we'll text you a code) <input type=tel data-expect=tel></label>
      <label>Verification code <input data-expect=none></label>
      <label>Gift card number <input data-expect=none></label>
      <label>Friend's email <input type=email data-expect=none></label>
      <label>Emergency contact name <input data-expect=none></label>
      <label>Project name <input data-expect=none></label>
      <label>Disabled <input name=email disabled data-expect=none></label>
      <label>Read only <input name=email readonly data-expect=none></label>
    </form>
    <form id=more>
      <div class=form-floating><input id=m1 placeholder=" " data-expect=email><label for=m1>Email</label></div>
      <span id=m2l>Mobile phone</span><input aria-labelledby=m2l data-expect=tel>
      <label>Email<span class=required>*</span> <input data-expect=email></label>
      <label>Confirm email <input data-expect=email></label>
      <label>Phone extension <input data-expect=none></label>
      <label>Organisation <input data-expect=organization></label>
      <input autocomplete="section-blue shipping address-level2" data-expect=address-level2>
      <input autocomplete="email webauthn" data-expect=email>
      <label>House name/number <input data-expect=address-line1></label>
      <label>Flat/Apartment number <input data-expect=address-line2></label>
      <label>Name on card <input data-expect=name></label>
      <label>Full name (as on your passport) <input data-expect=name></label>
      <label>Display name <input data-expect=nickname></label>
      <input placeholder="e.g. ada@example.com" data-expect=email>
      <label>Business email <input data-expect=email></label>
      <label>Work phone <input data-expect=tel></label>
      <label>Numer domu <input data-expect=house-number></label>
      <label>Numer mieszkania <input data-expect=address-line2></label>
      <label>メールアドレス <input data-expect=email></label>
      <label>お名前 <input data-expect=name></label>
      <label>Фамилия <input data-expect=family-name></label>
      <label>Search for your address <input type=search data-expect=none></label>
      <input type=search autocomplete=postal-code data-expect=postal-code>
    </form>
    <form id=honeypot>
      <label>Name <input data-expect=name></label><input name=lastname style="display:none">
      <label>Email <input type=email data-expect=email></label>
    </form>
    <form id=roboform>
      <label>Middle Initial <input name=mi data-expect=additional-name-initial></label>
      <label>Middle <input name=middle maxlength=1 data-expect=additional-name-initial></label>
      <label>Middle name <input name=middle_name data-expect=additional-name></label>
      <label>Home Phone <input data-expect=tel data-hint=home></label>
      <label>Work Telephone <input data-expect=tel data-hint=work></label>
      <label>Fax <input data-expect=tel data-hint=fax></label>
      <label>Cell Phone <input data-expect=tel data-hint=mobile></label>
      <label>Work email <input type=email data-expect=email data-hint=work></label>
      <label>Phone <input type=tel data-expect=tel data-hint=none></label>
    </form>
    <form id=address-postcode><label>Address <input data-expect=street-address></label><label>Postcode <input data-expect=postal-code></label></form>
    <table id=table>
      <tr><th>Email</th><td><input data-expect=email></td></tr>
      <tr><th>Telephone</th><td><input data-expect=tel></td></tr>
    </table>
    <x-field label="Email address"></x-field>
    <script>
      customElements.define('x-field', class extends HTMLElement {
        constructor() { super(); this.attachShadow({ mode: 'open' }).innerHTML = '<input data-expect=email>'; }
      });
    </script>
    """#

    @MainActor func testFieldsAreRecognisedFromTheirLabelsNamesAndNeighbours() async throws {
        // Fields from shops, sign-ups and job applications in English, French, Polish, German,
        // Spanish, Japanese and Russian, labelled and not.
        let (page, window) = try await page(Self.forms)
        defer { window.isHidden = true }
        let result = try await page.callAsyncJavaScript("""
            const fields = [...document.querySelectorAll('[data-expect]')];
            for (const host of document.querySelectorAll('x-field')) fields.push(...host.shadowRoot.querySelectorAll('[data-expect]'));
            const wrong = [];
            for (const el of fields) {
              const field = globalThis.__riseAutofill.describe(el);
              const got = field ? field.kind : 'none';
              const label = (el.closest('form, div')?.id || '') + ' ' + (el.labels?.[0]?.textContent || el.name || el.placeholder || el.getAttribute('autocomplete') || '').trim();
              if (got !== el.dataset.expect) wrong.push(label + ': ' + got + ' (wanted ' + el.dataset.expect + ')');
              if (el.dataset.national && String(!!field?.national) !== el.dataset.national) wrong.push(label + ': national ' + !!field?.national);
              if (el.dataset.hint && (field?.hint ?? 'none') !== el.dataset.hint) wrong.push(label + ': hint ' + field?.hint);
            }
            return { wrong, count: fields.length };
            """, contentWorld: FormAutofillScript.world) as? [String: Any]
        let wrong = result?["wrong"] as? [String] ?? ["no result"]
        XCTAssertEqual(wrong, [], wrong.joined(separator: "\n"))
        XCTAssertGreaterThan(result?["count"] as? Int ?? 0, 130)
    }

    /// Recognising a field happens as it's focused, so it has to be quick even in a long form.
    @MainActor func testRecognisingAFieldIsQuick() async throws {
        let (page, window) = try await page(Self.forms)
        defer { window.isHidden = true }
        let milliseconds = try await page.callAsyncJavaScript("""
            const fields = [...document.querySelectorAll('input, textarea')];
            const start = performance.now();
            for (let round = 0; round < 10; round++) for (const el of fields) globalThis.__riseAutofill.describe(el);
            return (performance.now() - start) / (10 * fields.length);
            """, contentWorld: FormAutofillScript.world) as? Double
        XCTAssertLessThan(try XCTUnwrap(milliseconds), 1.5, "each field took \(milliseconds ?? 0)ms")
    }

    // MARK: Writing a value as the field takes it

    @MainActor func testEachFieldGetsTheWayOfWritingItTakes() async throws {
        let (page, window) = try await page("""
            <input id=plain type=tel>
            <input id=short type=tel maxlength=11>
            <input id=intl type=tel placeholder="+44 7700 900000">
            <input id=national type=tel placeholder="07700 900000">
            <input id=numeric type=number>
            <input id=pattern type=tel pattern="[0-9]{10}">
            <input id=us placeholder="MM/DD/YYYY"><input id=de placeholder="TT.MM.JJJJ"><input id=pl placeholder="dd.mm.rrrr">
            <input id=iso placeholder="YYYY-MM-DD"><input id=date type=date>
            <input id=link type=url>
            """)
        defer { window.isHidden = true }
        let phone = PhoneFormats.variants("+44 7700 900123", region: "gb").map { ["v": $0.value, "t": $0.tags] }
        let birthday = [["v": "1990-03-07", "t": ["date"]]]
        let link = AutofillValues.urlVariants("http://linkedin.com/in/ada-example").map { ["v": $0.value, "t": $0.tags] }
        func written(_ id: String, _ kind: String, _ variants: [[String: Any]], national: Bool = false) async throws -> String? {
            let result = try await page.callAsyncJavaScript("""
                const el = document.getElementById(id); el.focus();
                const result = globalThis.__riseAutofill.prepare(globalThis.__riseAutofill.tokenOf(el), kind, variants, national);
                return result?.text ?? result?.value ?? null;
                """, arguments: ["id": id, "kind": kind, "variants": variants, "national": national],
                contentWorld: FormAutofillScript.world) as? String
            return result
        }
        let plainPhone = try await written("plain", "tel", phone)
        XCTAssertEqual(plainPhone, "+44 7700 900123")
        let shortPhone = try await written("short", "tel", phone)
        XCTAssertEqual(shortPhone, "07700900123")
        let intlPhone = try await written("intl", "tel", phone)
        XCTAssertEqual(intlPhone, "+44 7700 900123")
        let nationalPhone = try await written("national", "tel", phone)
        XCTAssertEqual(nationalPhone, "07700900123")
        let dialledPhone = try await written("plain", "tel", phone, national: true)
        XCTAssertEqual(dialledPhone, "7700900123")
        let numericPhone = try await written("numeric", "tel", phone)
        XCTAssertEqual(numericPhone, "07700900123")
        let patternPhone = try await written("pattern", "tel", phone)
        XCTAssertEqual(patternPhone, "7700900123")
        let us = try await written("us", "bday", birthday)
        XCTAssertEqual(us, "03/07/1990")
        let de = try await written("de", "bday", birthday)
        XCTAssertEqual(de, "07.03.1990")
        let pl = try await written("pl", "bday", birthday)
        XCTAssertEqual(pl, "07.03.1990")
        let iso = try await written("iso", "bday", birthday)
        XCTAssertEqual(iso, "1990-03-07")
        let date = try await written("date", "bday", birthday)
        XCTAssertEqual(date, "1990-03-07")
        let url = try await written("link", "url-linkedin", link)
        XCTAssertEqual(url, "https://linkedin.com/in/ada-example")
    }

    // MARK: Filling and undoing through the page

    /// As React's controlled inputs see it: a value set behind its back isn't a change, and the
    /// input event is what tells it.
    static let controlled = #"""
    <form><label>Email <input id=email type=email></label><label>First name <input id=first value="Someone"></label></form>
    <script>
      window.seen = {};
      for (const el of document.querySelectorAll('input')) {
        const proto = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
        let tracked = el.value;
        Object.defineProperty(el, 'value', { configurable: true, get() { return proto.get.call(this); },
          set(value) { tracked = value; proto.set.call(this, value); } });
        el.addEventListener('input', () => { const now = proto.get.call(el); if (now !== tracked) { tracked = now; window.seen[el.id] = now; } });
      }
    </script>
    """#

    @MainActor func testAFillLandsAsTypingWouldAndUndoPutsBackWhatWasThere() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "FormAutofillTests"))
        defaults.removePersistentDomain(forName: "FormAutofillTests")
        let store = AutofillStore(defaults: defaults, service: "dev.bartosz.Rise.autofill.tests")
        store.isEnabled = true
        try store.save(Self.profile)
        defer { store.revoke() }
        let (page, window) = try await page(Self.controlled)
        defer { window.isHidden = true }
        page.autofill = FormAutofill(webView: page, store: store)

        func focus(_ id: String, _ kind: String) async throws {
            _ = try await page.callAsyncJavaScript("document.getElementById(id).focus()", arguments: ["id": id], contentWorld: .page)
            for _ in 0..<200 where page.autofill.field?.kind != kind || page.autofill.choices.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func value(_ id: String) async throws -> [String] {
            let result = try await page.callAsyncJavaScript("return [document.getElementById(id).value, window.seen[id] ?? '']",
                                                            arguments: ["id": id], contentWorld: .page) as? [String]
            return result ?? []
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }

        // Three emails: the menu's, each with its label.
        try await focus("email", "email")
        XCTAssertEqual(page.autofill.field?.kind, "email")
        XCTAssertEqual(page.autofill.choices.map(\.title), ["ada@example.com", "ada@engines.example", "ada.l@example.org"])
        XCTAssertEqual(page.autofill.choices.map(\.subtitle), ["Home", "Work", "Home"])
        page.autofill.fill(page.autofill.choices[1])
        XCTAssertTrue(page.autofill.canUndo)
        try await settle()
        let filledEmail = try await value("email")
        XCTAssertEqual(filledEmail, ["ada@engines.example", "ada@engines.example"])
        page.autofill.undo()
        XCTAssertFalse(page.autofill.canUndo)
        XCTAssertEqual(page.autofill.choices.count, 3)
        try await settle()
        let undoneEmail = try await value("email")
        XCTAssertEqual(undoneEmail, ["", ""])

        // What was there is replaced, and comes back with Undo.
        try await focus("first", "given-name")
        XCTAssertEqual(page.autofill.choices.map(\.title), ["Ada"])
        page.autofill.fill(page.autofill.choices[0])
        try await settle()
        let filledName = try await value("first")
        XCTAssertEqual(filledName, ["Ada", "Ada"])
        page.autofill.undo()
        try await settle()
        let undoneName = try await value("first")
        XCTAssertEqual(undoneName, ["Someone", "Someone"])

        // In a frame, as checkouts put their address forms.
        _ = try await page.callAsyncJavaScript("""
            const frame = document.createElement('iframe');
            frame.srcdoc = '<label>Postcode <input id=zip></label>';
            document.body.append(frame);
            await new Promise(done => frame.onload = done);
            frame.contentDocument.getElementById('zip').focus();
            """, contentWorld: .page)
        for _ in 0..<200 where page.autofill.field?.kind != "postal-code" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(page.autofill.choices.map(\.title), ["CM1 1AA"])
        page.autofill.fill(page.autofill.choices[0])
        try await settle()
        let framed = try await page.callAsyncJavaScript("return document.querySelector('iframe').contentDocument.getElementById('zip').value",
                                                        contentWorld: .page) as? String
        XCTAssertEqual(framed, "CM1 1AA")

        // Off, the page isn't told anything is wanted of it.
        store.isEnabled = false
        _ = try await page.callAsyncJavaScript("document.activeElement.blur()", contentWorld: .page)
        _ = try await page.callAsyncJavaScript("document.getElementById('email').focus()", contentWorld: .page)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(page.autofill.field)
        XCTAssertTrue(page.autofill.choices.isEmpty)
    }

    // MARK: The card's values

    func testPhoneNumbersAreWrittenEveryWayFormsAskForThem() {
        XCTAssertEqual(PhoneFormats.variants("+44 7700 900123", region: "gb").map(\.value),
                       ["+44 7700 900123", "+447700900123", "07700900123", "7700900123", "447700900123"])
        XCTAssertEqual(PhoneFormats.variants("07700 900123", region: "gb").map(\.value),
                       ["07700 900123", "+447700900123", "07700900123", "7700900123", "447700900123"])
        XCTAssertEqual(PhoneFormats.parse("(555) 123-4567", region: "us"), .init(code: "1", number: "5551234567", region: "us"))
        XCTAssertEqual(PhoneFormats.parse("+48 512 345 678", region: "gb"), .init(code: "48", number: "512345678", region: "pl"))
        XCTAssertEqual(PhoneFormats.parse("+1 416 555 0100", region: "ca"), .init(code: "1", number: "4165550100", region: "ca"))
        XCTAssertEqual(PhoneFormats.parse("0044 20 7946 0000 ext. 12", region: nil), .init(code: "44", number: "2079460000", region: "gb"))
        XCTAssertEqual(PhoneFormats.variants("+48 512 345 678", region: nil).map(\.value)[2], "512345678", "Poland has no trunk prefix")
        XCTAssertNil(PhoneFormats.parse("123", region: "gb"))
    }

    func testStreetsSplitIntoStreetAndNumber() {
        func split(_ street: String) -> [String]? {
            let address = AutofillProfile.Address(label: "", street: street, subLocality: "", city: "", subAdministrativeArea: "",
                                                  state: "", postalCode: "", country: "", isoCountryCode: "")
            return AutofillValues.splitStreet(address).map { [$0.street, $0.number] }
        }
        XCTAssertEqual(split("Hauptstraße 12"), ["Hauptstraße", "12"])
        XCTAssertEqual(split("10 Downing Street"), ["Downing Street", "10"])
        XCTAssertEqual(split("ul. Marszałkowska 10/12"), ["ul. Marszałkowska", "10/12"])
        XCTAssertEqual(split("Calle Mayor, 5"), ["Calle Mayor", "5"])
        XCTAssertEqual(split("221B Example Street"), ["Example Street", "221B"])
        XCTAssertEqual(split("Flat 2\n10 Example Road"), ["Example Road", "10"])
        XCTAssertNil(split("The Old Rectory"))
    }

    func testEachKindOfFieldGetsWhatTheCardHas() {
        let profile = Self.profile
        func titles(_ kind: String, multiline: Bool = false) -> [String] {
            AutofillValues.choices(for: kind, in: profile, multiline: multiline, language: "en-GB",
                                   now: Date(timeIntervalSince1970: 1_795_000_000)).map(\.title)
        }
        XCTAssertEqual(titles("name"), ["Ada Lovelace"])
        XCTAssertEqual(titles("given-name"), ["Ada"])
        XCTAssertEqual(titles("additional-name"), ["Augusta"])
        XCTAssertEqual(titles("email").count, 3)
        XCTAssertEqual(titles("tel"), ["+44 7700 900123"])
        XCTAssertEqual(titles("tel-country-code"), ["+44"])
        XCTAssertEqual(titles("address-line1"), ["12 Example Avenue"])
        XCTAssertEqual(titles("address-line2"), ["Little Testing"])
        XCTAssertEqual(titles("street-address"), ["12 Example Avenue, Little Testing"])
        XCTAssertEqual(titles("street-address", multiline: true), ["12 Example Avenue\nLittle Testing"])
        XCTAssertEqual(titles("street-name"), ["Example Avenue"])
        XCTAssertEqual(titles("house-number"), ["12"])
        XCTAssertEqual(titles("address-level2"), ["Chelmsford"])
        XCTAssertEqual(titles("county"), ["Essex"])
        XCTAssertEqual(titles("postal-code"), ["CM1 1AA"])
        XCTAssertEqual(titles("country"), ["United Kingdom"])
        XCTAssertEqual(titles("organization"), ["Analytical Engines"])
        XCTAssertEqual(titles("bday-day"), ["07"])
        XCTAssertEqual(titles("bday-year"), ["1990"])
        XCTAssertEqual(titles("age"), ["36"])
        XCTAssertEqual(titles("url-linkedin"), ["http://linkedin.com/in/ada-example"])
        XCTAssertEqual(titles("url-github"), ["http://github.com/ada-example"])
        XCTAssertEqual(titles("url").count, 2)
        XCTAssertEqual(titles("url-x"), [])
        XCTAssertTrue(titles("address-full")[0].contains("CM1 1AA"))
        XCTAssertEqual(titles("honorific-prefix"), [])

        // A locality the card keeps apart is line 2 where the street has one line.
        var apart = profile
        apart.addresses[0].street = "12 Example Avenue"; apart.addresses[0].subLocality = "Little Testing"
        XCTAssertEqual(AutofillValues.choices(for: "address-line2", in: apart).map(\.title), ["Little Testing"])
    }

    func testAUKAddressFillsItsCountyRatherThanItsNation() {
        var profile = Self.profile
        // As Apple's address search writes a UK address: the nation where the county goes.
        profile.addresses[0].state = "England"; profile.addresses[0].subAdministrativeArea = ""
        func titles(_ kind: String) -> [String] { AutofillValues.choices(for: kind, in: profile).map(\.title) }
        XCTAssertTrue(profile.addresses[0].needsCountyLookup)
        XCTAssertEqual(titles("address-level1"), ["England"])
        XCTAssertEqual(titles("county"), ["England"])

        profile.addresses[0].lookedUpCounty = "Essex"
        XCTAssertFalse(profile.addresses[0].needsCountyLookup)
        XCTAssertEqual(titles("address-level1"), ["Essex"])
        XCTAssertEqual(titles("county"), ["Essex"])
        let full = AutofillValues.fullAddress(profile.addresses[0], multiline: false)
        XCTAssertTrue(full.contains("Essex"), full)
        XCTAssertFalse(full.contains("England"), full)

        // None found: the nation still, and not looked up again.
        profile.addresses[0].lookedUpCounty = ""
        XCTAssertFalse(profile.addresses[0].needsCountyLookup)
        XCTAssertEqual(titles("address-level1"), ["England"])

        // The card's own county, or the one Maps gave an address found there, needs no lookup.
        profile.addresses[0].lookedUpCounty = nil
        profile.addresses[0].state = "Essex"
        XCTAssertFalse(profile.addresses[0].needsCountyLookup)
        XCTAssertEqual(titles("address-level1"), ["Essex"])
        profile.addresses[0].state = "England"; profile.addresses[0].subAdministrativeArea = "Essex"
        XCTAssertFalse(profile.addresses[0].needsCountyLookup)
        XCTAssertEqual(titles("address-level1"), ["Essex"])

        // Elsewhere, the state is the state.
        profile.addresses = [.init(label: "Home", street: "1 Example Way", subLocality: "", city: "Springfield",
                                   subAdministrativeArea: "Sangamon County", state: "IL", postalCode: "62701",
                                   country: "United States", isoCountryCode: "us")]
        XCTAssertFalse(profile.addresses[0].needsCountyLookup)
        XCTAssertEqual(titles("address-level1"), ["IL"])
        XCTAssertEqual(titles("county"), ["Sangamon County"])

        // A copy kept before counties were looked up still reads, as due one.
        var old = Self.profile
        old.addresses[0].state = "England"
        let json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        XCTAssertNil((json["addresses"] as! [[String: Any]])[0]["lookedUpCounty"])
        let read = try! JSONDecoder().decode(AutofillProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(read.addresses[0].needsCountyLookup)
    }

    @MainActor func testTheButtonOffersOnlyWhatTheFieldDoesntHaveAndFits() {
        let choices = AutofillValues.choices(for: "email", in: Self.profile)
        let field = FormAutofill.Field(kind: "email", national: false, multiline: false, value: "ADA@example.com ", maxLength: 0, language: nil)
        XCTAssertEqual(FormAutofill.offered(choices, for: field, lastAddress: nil).map(\.title), ["ada@engines.example", "ada.l@example.org"])
        let short = FormAutofill.Field(kind: "email", national: false, multiline: false, value: "", maxLength: 16, language: nil)
        XCTAssertEqual(FormAutofill.offered(choices, for: short, lastAddress: nil).map(\.title), ["ada@example.com"])
    }

    func testAMiddleInitialComesFromTheMiddleName() {
        XCTAssertEqual(AutofillValues.choices(for: "additional-name-initial", in: Self.profile).map(\.title), ["A"])
        XCTAssertEqual(AutofillValues.choices(for: "additional-name-initial", in: Self.profile).first?.variants.map(\.value), ["A", "A."])
        // A middle name's field too short for it takes the initial.
        XCTAssertEqual(AutofillValues.choices(for: "additional-name", in: Self.profile).first?.variants.map(\.value), ["Augusta", "A", "A."])
        var none = Self.profile
        none.middleName = ""
        XCTAssertEqual(AutofillValues.choices(for: "additional-name-initial", in: none), [])
    }

    @MainActor func testAFieldsLabelPicksWhichNumberOrEmail() {
        var profile = Self.profile
        profile.phones = [.init(label: "Mobile", number: "+44 7700 900123", region: "gb"),
                          .init(label: "Home", number: "+44 1632 960001", region: "gb"),
                          .init(label: "Work", number: "+44 1632 960002", region: "gb")]
        func offered(_ kind: String, hint: String?) -> [String] {
            let field = FormAutofill.Field(kind: kind, national: false, multiline: false, value: "", maxLength: 0, language: nil, hint: hint)
            return FormAutofill.offered(AutofillValues.choices(for: kind, in: profile), for: field, lastAddress: nil).map(\.title)
        }
        XCTAssertEqual(offered("tel", hint: "work"), ["+44 1632 960002"])
        XCTAssertEqual(offered("tel", hint: "home"), ["+44 1632 960001"])
        XCTAssertEqual(offered("tel", hint: "mobile"), ["+44 7700 900123"])
        XCTAssertEqual(offered("tel", hint: nil).count, 3)
        // No fax number: nothing for a fax field. One for it: only that.
        XCTAssertEqual(offered("tel", hint: "fax"), [])
        profile.phones.append(.init(label: "Home Fax", number: "+44 1632 960003", region: "gb"))
        XCTAssertEqual(offered("tel", hint: "fax"), ["+44 1632 960003"])
        XCTAssertEqual(offered("tel", hint: "home"), ["+44 1632 960001"])
        XCTAssertEqual(offered("email", hint: "work"), ["ada@engines.example"])
        // None labelled so: every one, as without a hint.
        profile.phones = [.init(label: "Mobile", number: "+44 7700 900123", region: "gb")]
        XCTAssertEqual(offered("tel", hint: "work"), ["+44 7700 900123"])
    }

    func testAddressLinesEditAsTheyShow() {
        var address = AutofillProfile.Address.empty()
        address.street = "12 Example Avenue"; address.subLocality = "Little Testing"
        XCTAssertEqual(address.line2, "Little Testing")
        address.line2 = "Old Testing"
        XCTAssertEqual(address.subLocality, "Old Testing"); XCTAssertEqual(address.street, "12 Example Avenue")
        address.street = "Flat 2\n12 Example Avenue"
        XCTAssertEqual(address.line1, "Flat 2"); XCTAssertEqual(address.line2, "12 Example Avenue")
        address.line2 = "14 Example Avenue"
        XCTAssertEqual(address.street, "Flat 2\n14 Example Avenue")
        address.line2 = ""
        XCTAssertEqual(address.street, "Flat 2")
        var empty = AutofillProfile.Address.empty()
        empty.line2 = "Little Testing"
        XCTAssertEqual(empty.line1, ""); XCTAssertEqual(empty.line2, "Little Testing")
        empty.line1 = "1 Sample Road"
        XCTAssertEqual(empty.street, "1 Sample Road\nLittle Testing")
        // A county typed in is the county, though the card had only the nation.
        var nation = Self.profile.addresses[0]
        nation.state = "England"; nation.lookedUpCounty = "Essex"
        XCTAssertEqual(nation[.county], "Essex")
        nation[.county] = "Kent"
        XCTAssertEqual(nation.county, "Kent"); XCTAssertFalse(nation.needsCountyLookup)
    }

    func testRefreshingTheCardKeepsWhatWasAddedInRise() {
        var card = Self.profile
        card.jobTitle = ""
        card.addresses[0].state = "England"
        var mine = card
        mine.addresses[0].lookedUpCounty = "Essex"
        mine.set(.givenName, to: "Addie")          // The card has one: the card's wins.
        mine.set(.jobTitle, to: "Analyst")         // The card has none: kept.
        mine.set(.namePrefix, to: "Dr")
        mine.emails[0].value = "changed@example.com" // A card's email, changed: the card's again.
        mine.emails.append(.init(label: "Work", value: "ada@new.example", added: true))
        mine.phones.append(.init(label: "Work", number: "+44 1632 960002", region: "gb", added: true))
        mine.birthday = nil
        XCTAssertEqual(mine.edited, ["givenName", "jobTitle", "namePrefix"])

        var newer = card
        newer.emails.append(.init(label: "School", value: "ada@uni.example"))
        newer.phones.append(.init(label: "Work", number: "+441632960002", region: "gb")) // The same, as the card has it.
        let merged = mine.refreshed(with: newer)
        XCTAssertEqual(merged.givenName, "Ada")
        XCTAssertEqual(merged.jobTitle, "Analyst")
        XCTAssertEqual(merged.namePrefix, "Dr")
        XCTAssertEqual(merged.edited, ["jobTitle", "namePrefix"])
        XCTAssertEqual(merged.emails.map(\.value), ["ada@example.com", "ada@engines.example", "ada.l@example.org", "ada@uni.example", "ada@new.example"])
        XCTAssertEqual(merged.phones.map(\.number), ["+44 7700 900123", "+441632960002"])
        XCTAssertEqual(merged.birthday, card.birthday)
        XCTAssertEqual(merged.addresses[0].lookedUpCounty, "Essex")

        // A card without an address keeps the one typed in; one with its own replaces it.
        var typed = card
        typed.addresses = []
        typed.set(.line1, to: "1 Sample Road"); typed.set(.city, to: "Testbury")
        var bare = card
        bare.addresses = []
        let kept = typed.refreshed(with: bare)
        XCTAssertEqual(kept.addresses.first?.line1, "1 Sample Road")
        XCTAssertEqual(kept.addresses.first?.city, "Testbury")
        XCTAssertEqual(typed.refreshed(with: card).addresses.first?.city, "Chelmsford")
        // Moved house: the old county isn't carried to the new address.
        var moved = card
        moved.addresses[0].postalCode = "CM2 2BB"
        XCTAssertNil(mine.refreshed(with: moved).addresses[0].lookedUpCounty)

        // What was added and typed is kept with the copy.
        let decoded = try? JSONDecoder().decode(AutofillProfile.self, from: JSONEncoder().encode(merged))
        XCTAssertEqual(decoded, merged)
    }

    func testACardCopiesEverythingAFormMightAskFor() {
        let contact = CNMutableContact()
        contact.givenName = " Ada "; contact.familyName = "Lovelace"; contact.organizationName = "Analytical Engines"
        contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "ada@example.com"),
                                  CNLabeledValue(label: "school", value: "ada@uni.example")]
        contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "07700 900123"))]
        let address = CNMutablePostalAddress()
        address.street = "12 Example Avenue"; address.city = "Chelmsford"; address.postalCode = "CM1 1AA"; address.isoCountryCode = "GB"
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address)]
        contact.urlAddresses = [CNLabeledValue(label: "GitHub", value: "http://github.com/ada-example")]
        contact.birthday = DateComponents(month: 3, day: 7)
        let profile = AutofillProfile(contact: contact, region: "us")
        XCTAssertEqual(profile.givenName, "Ada")
        XCTAssertEqual(profile.emails.map(\.label), ["Home", "School"])
        XCTAssertEqual(profile.phones.first?.region, "gb", "a number without a country is the address's")
        XCTAssertEqual(profile.addresses.first?.isoCountryCode, "gb")
        XCTAssertEqual(profile.birthday, .init(day: 7, month: 3, year: nil))
        XCTAssertEqual(profile.urls.first?.value, "http://github.com/ada-example")
        XCTAssertEqual(AutofillValues.choices(for: "age", in: profile), [], "no year, no age")
        // Saved and read back, older copies without a field included.
        let data = try! JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(AutofillProfile.self, from: data), profile)
        XCTAssertEqual(try JSONDecoder().decode(AutofillProfile.self, from: Data(#"{"givenName":"Ada"}"#.utf8)).givenName, "Ada")
    }
}
