//
//  ZeroLogger.swift
//  ZeroLogger
//
//  Created by Evan Kimia on 12/20/16.
//  Copyright © 2016 zero. All rights reserved.
//

import Foundation
import GRDB
import CocoaLumberjack


typealias LogFailure = (task: URLSessionUploadTask, response: HTTPURLResponse)


class LogRecord : Record {
    var uuid: String
    var message: String
    var flag: Int
    var level: Int
    var date: Date
    var uploadTaskID: Int?

    required init(row: Row) {
        uuid = row.value(named: "uuid")
        message = row.value(named: "message")
        flag = row.value(named: "flag")
        level = row.value(named: "level")
        date = row.value(named: "date")
        uploadTaskID = row.value(named: "upload_task_id")

        super.init(row: row)
    }

    init(logMessage: DDLogMessage) {
        uuid = UUID().uuidString
        message = logMessage.message
        flag = Int(logMessage.flag.rawValue)
        level = Int(logMessage.level.rawValue)
        date = logMessage.timestamp
        
        super.init()
    }
    
    override var persistentDictionary: [String: DatabaseValueConvertible?] {
        return ["uuid": uuid,
                "message": message,
                "flag": flag,
                "level": level,
                "date": date
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
        
        return dict
    }
}


public class ZeroLogger: DDAbstractLogger, URLSessionTaskDelegate {
    var dbQueue: DatabaseQueue?
    var urlSession: URLSessionProtocol
    var logUploadEndpoint: URL?
    
    var logFailureBlock:( (_: [LogFailure]) -> Void )?
    private let urlSessionIdentifier: String
    private let databasePath: String

    
    private static let defaultDBPath: String = "Documents/loggerdb.sqlite"
    

    /// Initializes the logger using GRDB to interface with SQLite, and your standard URLSession for uploading
    /// logs to the specified server.
    ///
    /// - Parameters:
    ///   - dbPath: Location for storing the database containing logs. Please be careful not to specify a nonpersistent
    ///   location for production use.
    ///
    ///   - logUploadEndpoint: URL to upload logs. See the `persistentDictionary` method on `LogRecord` for information
    ///   on the payload structure.
    ///
    ///   - session: session to use to upload the logs. If one is not provided a background session will be made
    ///
    /// - Throws: A DatabaseError is thrown whenever an SQLite error occurs. See the GRDB documentation here
    ///   for more information: https://github.com/groue/GRDB.swift#documentation
    ///
    required public init(dbPath: String?, logUploadEndpoint: URL? = nil, session: URLSessionProtocol? = nil) throws {
        if let dbPath = dbPath {
            databasePath = dbPath
        } else {
            databasePath = ZeroLogger.defaultDBPath
        }
        dbQueue = try DatabaseQueue(path: databasePath)
        
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
            }
        }
    }
    
    override init() {
        fatalError("Please use init(dbPath:) instead.")
    }
    
    func reset() throws {
        if FileManager.default.fileExists(atPath: databasePath) {
            try FileManager.default.removeItem(atPath: databasePath)
        }
    }
    
    func flushLogs(callback: ((_ uploadedLogs: LogRecord, _ error: Error?) -> Void)?) throws {
        guard let logUploadEndpoint = logUploadEndpoint else { return }
        try dbQueue?.inDatabase({ db in
            let logRecords = try LogRecord.filter(Column("upload_task_id") == nil).fetchAll(db)
            for record in logRecords {
                do {
                    let jsonData = try JSONSerialization.data(withJSONObject: record.dict(), options: .prettyPrinted)
                    let logUploadRequest = URLRequest(url: logUploadEndpoint)
                    let task = urlSession.uploadTask(with: logUploadRequest, from: jsonData, completionHandler: { (_, _, _) in
                        callback?(record, nil)
                    })
                    task.resume()
                    
                    record.uploadTaskID = task.taskIdentifier
                    try record.save(db)
                } catch {
                    callback?(record, error)
                }
            }
        })
    }
    
    public func processLogTasks(tasks: [URLSessionUploadTask]) throws {
        var failedLogUploads: [LogFailure] = []
        try dbQueue?.inTransaction { db in
            for task in tasks {
                guard let record = try LogRecord.filter(Column("upload_task_id") == task.taskIdentifier).fetchOne(db) else { continue }
                if let httpResponse = task.response as? HTTPURLResponse {
                    if httpResponse.statusCode != 200 {
                        record.uploadTaskID = nil
                        // Tell our delegate we ran into trouble uploading the given logs
                        let logUploadFailure = LogFailure(task: task, response: httpResponse)
                        failedLogUploads.append(logUploadFailure)
                    }
                    try record.delete(db)
                }
            }

            return .commit
        }
    }
    
    // MARK: DDAbstractLogger Methods

    override public func log(message logMessage: DDLogMessage!) {
        // Generate a LogRecord from a LogMessage
        let logRecord = LogRecord(logMessage: logMessage)
        try! dbQueue?.inDatabase({ db in
            try logRecord.insert(db)
        })
    }
}
