//
//  Relay.swift
//  Relay
//
//  Created by Evan Kimia on 12/20/16.
//  Copyright © 2016 zero. All rights reserved.
//

import Foundation
import GRDB
import CocoaLumberjack


class LogRecord : Record {
    var uuid: String
    var message: String
    var flag: Int
    var level: Int
    var date: Date
    var uploadTaskID: Int?
    var uploaded = false
    var loggerIdentifier: String


    required init(row: Row) {
        uuid = row.value(named: "uuid")
        message = row.value(named: "message")
        flag = row.value(named: "flag")
        level = row.value(named: "level")
        date = row.value(named: "date")
        uploadTaskID = row.value(named: "upload_task_id")
        uploaded = row.value(named: "uploaded")
        loggerIdentifier = row.value(named: "logger_identifier")

        super.init(row: row)
    }

    init(logMessage: DDLogMessage, loggerIdentifier: String) {
        uuid = UUID().uuidString
        message = logMessage.message
        flag = Int(logMessage.flag.rawValue)
        level = Int(logMessage.level.rawValue)
        date = logMessage.timestamp
        self.loggerIdentifier = loggerIdentifier

        super.init()
    }
    
    override var persistentDictionary: [String: DatabaseValueConvertible?] {
        return ["uuid": uuid,
                "message": message,
                "flag": flag,
                "level": level,
                "date": date,
                "uploaded": uploaded,
                "logger_identifier": loggerIdentifier
        ]
    }
    
    override class var databaseTableName: String {
        return "log_messages"
    }

    func dict() -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["uuid"] = uuid
        dict["message"] = message
        dict["flag"] = flag
        dict["level"] = level
        dict["date"] = date.description
        dict["uploaded"] = uploaded
        
        return dict
    }
}


public class Relay: DDAbstractLogger, URLSessionTaskDelegate {
    var identifier: String
    var configuration: RelayRemoteConfiguration?
    var dbQueue: DatabaseQueue?
    var urlSession: URLSessionProtocol
    
    private let urlSessionIdentifier: String
    private let dbPath: String = "Documents/loggerdb.sqlite"
    

    /// Initializes the logger using GRDB to interface with SQLite, and your standard URLSession for uploading
    /// logs to the specified server.
    ///
    /// - Parameters:
    ///   - dbPath: Location for storing the database containing logs. Please be careful not to specify a nonpersistent
    ///   location for production use.
    ///
    ///   - configuration: Remote configuration for uploading logs. See the `persistentDictionary` method on `LogRecord` for information
    ///   on the JSON body and the `RelayRemoteConfiguration` class for options.
    ///
    ///   - session: session to use to upload the logs. If one is not provided a background session will be made
    ///
    /// - Throws: A DatabaseError is thrown whenever an SQLite error occurs. See the GRDB documentation here
    ///   for more information: https://github.com/groue/GRDB.swift#documentation
    ///
    required public init(identifier: String, configuration: RelayRemoteConfiguration? = nil, session: URLSessionProtocol? = nil) throws {
        
        self.identifier = identifier
        self.configuration = configuration

        dbQueue = try DatabaseQueue(path: dbPath)
        
        if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
            print("Documents Directory: " + documentsPath)
        }
        
        if let session = session {
            urlSession = session
        } else {
            // Setup a background NSURLSession
            let backgroundConfig = URLSessionConfiguration.background(withIdentifier: "zerofinancial.inc.logger")
            urlSession = URLSession(configuration: backgroundConfig)
        }
        
        urlSessionIdentifier = urlSession.configuration.identifier!
        
        try dbQueue?.inDatabase { db in
            guard try !db.tableExists(identifier) else { return }

            try db.create(table: "log_messages") { t in
                t.column("id", .integer).primaryKey()
                t.column("uuid", .text)
                t.column("message", .text)
                t.column("flag", .integer).notNull()
                t.column("level", .integer).notNull()
                t.column("context", .text)
                t.column("file", .text)
                t.column("function", .text)
                t.column("line", .integer)
                t.column("date", .datetime)
                t.column("upload_task_id", .integer)
                t.column("uploaded", .boolean).notNull().defaults(to: false)
                t.column("logger_identifier", .text)
            }
        }
    }
    
    override init() {
        fatalError("Please use init(dbPath:) instead.")
    }
    
    func reset() throws {
        try dbQueue?.inDatabase({ db in
            try db.drop(table: identifier)
        })
    }
    
    func flushLogs(callback: ((_ flushedLog: LogRecord, _ error: Error?, _ db: GRDB.Database) -> Void)? = nil) throws {
        guard let logUploadEndpoint = configuration?.host else { return }
        try dbQueue?.inDatabase({ db in
            let logRecords = try LogRecord.filter(Column("upload_task_id") == nil).fetchAll(db)
            for record in logRecords {
                do {
                    let jsonData = try JSONSerialization.data(withJSONObject: record.dict(), options: .prettyPrinted)
                    let logUploadRequest = URLRequest(url: logUploadEndpoint)
                    let task = urlSession.uploadTask(with: logUploadRequest, from: jsonData, completionHandler: { data, response, error in
                        record.uploaded = error == nil
                        callback?(record, error, db)
                    })
                    task.resume()
                    
                    record.uploadTaskID = task.taskIdentifier
                    try record.save(db)
                } catch {
                    callback?(record, error, db)
                }
            }
        })
    }
    
    public func processLogUploadTasks(tasks: [URLSessionUploadTask]) throws {
        try dbQueue?.inTransaction { db in
            for task in tasks {
                guard let record = try LogRecord.filter(Column("upload_task_id") == task.taskIdentifier).fetchOne(db) else { continue }
                if let httpResponse = task.response as? HTTPURLResponse {
                    if httpResponse.statusCode != 200 {
                        record.uploadTaskID = nil
                        try record.save(db)
                    } else {
                        try record.delete(db)
                    }
                }
            }

            return .commit
        }
    }
    
    // MARK: DDAbstractLogger Methods

    override public func log(message logMessage: DDLogMessage!) {
        // Generate a LogRecord from a LogMessage
        let logRecord = LogRecord(logMessage: logMessage, loggerIdentifier: identifier)
        try! dbQueue?.inDatabase({ db in
            try logRecord.insert(db)
        })
    }
}