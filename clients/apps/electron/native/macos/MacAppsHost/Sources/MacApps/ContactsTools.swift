import Contacts
import Foundation
import MCP

enum ContactsTools {
    static let all: [ToolDefinition] = [search, get]

    static let search = ToolDefinition(
        app: .contacts,
        name: "search",
        title: "Search contacts",
        description: "Finds people in the user's Contacts by name, phone number or email address. A query with @ matches email, one that is mostly digits matches phone numbers, anything else matches names.",
        inputSchema: Schema.object([
            "query": Schema.string("A name, phone number or email address."),
            "limit": Schema.integer(Schema.limitDescription, minimum: 1, maximum: 50),
        ], required: ["query"]),
        readOnly: true,
        requirements: [.contacts]
    ) { arguments, _ in
        let query = try arguments.requiredString("query")
        let limit = try arguments.limit(default: 20, max: 50)
        let contacts = try CNContactStore().unifiedContacts(matching: predicate(for: query), keysToFetch: summaryKeys)
        return [
            "contacts": .array(contacts.prefix(limit).map(summary)),
            "truncated": .bool(contacts.count > limit),
        ]
    }

    static let get = ToolDefinition(
        app: .contacts,
        name: "get",
        title: "Get contact",
        description: "Reads one contact: names, organization, phone numbers, email and postal addresses, birthday and links.",
        inputSchema: Schema.object([
            "id": Schema.string("Contact id from contacts_search."),
        ], required: ["id"]),
        readOnly: true,
        requirements: [.contacts]
    ) { arguments, _ in
        let id = try arguments.requiredString("id")
        let contact: CNContact
        do {
            contact = try CNContactStore().unifiedContact(withIdentifier: id, keysToFetch: detailKeys)
        } catch {
            throw ToolFailure.notFound("No contact has id \(id).")
        }
        var value = summary(contact).objectValue ?? [:]
        value["given_name"] = .string(contact.givenName)
        value["middle_name"] = .string(contact.middleName)
        value["family_name"] = .string(contact.familyName)
        value["nickname"] = .string(contact.nickname)
        value["job_title"] = .string(contact.jobTitle)
        value["department"] = .string(contact.departmentName)
        value["postal_addresses"] = .array(contact.postalAddresses.map { address in
            [
                "label": .string(label(address.label)),
                "address": .string(CNPostalAddressFormatter.string(from: address.value, style: .mailingAddress)),
            ]
        })
        value["urls"] = .array(contact.urlAddresses.map { url in
            ["label": .string(label(url.label)), "value": .string(url.value as String)]
        })
        if let birthday = contact.birthday {
            value["birthday"] = .string(birthdayText(birthday))
        }
        return ["contact": .object(value)]
    }

    // MARK: - Helpers

    private static let summaryKeys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    private static let detailKeys: [CNKeyDescriptor] = summaryKeys + [
        CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
        CNContactJobTitleKey, CNContactDepartmentNameKey, CNContactPostalAddressesKey,
        CNContactUrlAddressesKey, CNContactBirthdayKey,
    ].map { $0 as CNKeyDescriptor }

    static func predicate(for query: String) -> NSPredicate {
        if query.contains("@") {
            return CNContact.predicateForContacts(matchingEmailAddress: query)
        }
        let digits = query.filter(\.isNumber)
        let other = query.filter { !$0.isNumber && !" +-().".contains($0) }
        if digits.count >= 5, other.isEmpty {
            return CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))
        }
        return CNContact.predicateForContacts(matchingName: query)
    }

    private static func summary(_ contact: CNContact) -> Value {
        [
            "id": .string(contact.identifier),
            "name": .string(CNContactFormatter.string(from: contact, style: .fullName) ?? ""),
            "organization": .string(contact.organizationName),
            "phones": .array(contact.phoneNumbers.map { phone in
                ["label": .string(label(phone.label)), "value": .string(phone.value.stringValue)]
            }),
            "emails": .array(contact.emailAddresses.map { email in
                ["label": .string(label(email.label)), "value": .string(email.value as String)]
            }),
        ]
    }

    private static func label(_ raw: String?) -> String {
        guard let raw else { return "" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }

    private static func birthdayText(_ parts: DateComponents) -> String {
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        if let year = parts.year { return String(format: "%04d-%02d-%02d", year, month, day) }
        return String(format: "--%02d-%02d", month, day)
    }
}
