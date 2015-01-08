if Meteor.isServer
    
    # 
    # Constants
    #

    if (process.env.ROOT_URL)
        DWOLLA_OAUTH_REDIRECT_URL = process.env.ROOT_URL + '/dwollaOAuthReturn'
    else
        DWOLLA_OAUTH_REDIRECT_URL = 'http://localhost:3000/dwollaOAuthReturn'

    # Set up Dwolla API bindings
    Dwolla = Meteor.npmRequire('dwolla-node')
    dwolla = Dwolla(process.env.DWOLLA_KEY, process.env.DWOLLA_SECRET)
    dwolla.sandbox = true

    # wrap the async dwolla methods so that they are synchronous
    dwolla.finishAuthSync = Meteor.wrapAsync dwolla.finishAuth
    dwolla.fullAccountInfoSync = Meteor.wrapAsync dwolla.fullAccountInfo
    dwolla.sendSync = Meteor.wrapAsync dwolla.send
    
    
    # Define AWS config    
    S3.config = 
        key: process.env.XPENZ_S3_KEY,
        secret: process.env.XPENZ_S3_SECRET,
        bucket: process.env.XPENZ_S3_BUCKET

    # Define a small 'enum' for sending email messages
    mailType = 
        APPROVED: 0,
        REJECTED: 1,
        REIMBURSED: 2

    #
    # OAuth and registration
    #

    Meteor.methods
        reimburseCheckedExpenses: (expenseIds, pin) ->
            if not Roles.userIsInRole this.userId, ['accountant', 'superAccountant']
                throw new Meteor.Error 'reimburse-fail', 'User is not allowed to reimburse expenses'

            expenses = Expenses.find(
                _id: {$in: expenseIds}
                status: 'PendingReimbursement'
            ).fetch()

            # Create payment objects: lump expenses into batches based on type and employee
            payments = []
            employeesToExpenses = _.groupBy(expenses, (expense) -> expense.employeeId)
            employeesToExpensesByType = _.each _.keys(employeesToExpenses), (employeeId) ->
                expensesByType = _.groupBy(employeesToExpenses[employeeId], (expense) -> expense.type)
                _.each _.keys(expensesByType), (type) ->
                    payments.push {
                        employeeId: employeeId,
                        expenseType: type,
                        expenses: expensesByType[type]
                    }

            console.log(payments)

            # process those payments
            payments.forEach((payment) -> processPayment(payment, Meteor.user(), pin))

            return true

        OAuthGetURL: () ->
            dwolla.authUrl(DWOLLA_OAUTH_REDIRECT_URL)

        OAuthFinish: (code) ->
            if !code
                throw new Meteor.Error 'oauth-fail', 'Could not authorize account'

            # try to fetch access token
            auth = dwolla.finishAuthSync(code, DWOLLA_OAUTH_REDIRECT_URL)

            if auth && auth.error == 'access_denied'
                throw new Meteor.Error 'oauth-fail', 'Could not authorize account, could not get token' 
            
            # Call the Dwolla Account Info API to get the user's Dwolla ID, and see if a user with that ID already has an account
            dwolla.setToken(auth.access_token)
            accountInfo = dwolla.fullAccountInfoSync()
            foundUser = Meteor.users.findOne({'profile.dwollaId': accountInfo.Id})

            if foundUser
                Meteor.users.update({_id: foundUser._id}, {$set: {'profile.auth': auth}})
                this.setUserId(foundUser._id)
                return { 
                    resultCode: 'user-logged-in', 
                    auth: auth,
                    userId: foundUser._id
                }
            else
                return { 
                    resultCode: 'create-new-user', 
                    auth: auth,
                    dwollaId: accountInfo.Id, 
                    name: accountInfo.Name
                }
        
            return dwollaId

        registerUser: (email, dwollaId, name, managerId, auth) ->
            randomPassword = Math.random().toString(36).slice(2)
            userId = Accounts.createUser
                email: email,
                password: randomPassword, # TODO: don't rely on accounts-password for accounts...
                profile: 
                  name: name,
                  dwollaId: dwollaId,
                  managerId: managerId
                  auth: auth

            this.setUserId(userId)

            return userId
        
        registerInvite: (email, dwollaId, name, auth) ->
            
            

        #
        # Email methods:
        #
        # userId: user to send mail to
        # action: enum to identify event clearly
        #

        sendMail: (userId, type, action, amount=false) ->
            console.log('sm called')
            dest = Meteor.users.findOne({_id: userId})
            kw = ''
            news = ''

            switch action
                when mailType.APPROVED
                    kw = 'approve'
                    news = 'approved by your manager and is pending reimbursement!'
                when mailType.REJECTED
                    kw = 'rejected'
                    news = 'rejected by your manager. Sorry!'
                when mailType.REIMBURSED
                    kw = 'reimbursed'
                    news = 'reimbursed in the amount of $' + amount + ' and should now be available in your Dwolla balance!'
                else return

            subj = 'xpenz: Your expense has been ' + kw + '.'

            Email.send(
                from: "xpenz@dwolla.com",
                to: dest.emails[0]['address'],
                subject: subj,
                text: 'Hello ' + dest.profile.name + '!\n'+ 'An expense you submitted for ' + type
                + ' has been' + news)

            console.log('xpenz: Email sent to ' + userId + ' regarding a ' + type + ' expense.')

        inviteMail: (email, managerId) ->
            mgr = Meteor.users.findOne({_id: managerId})
            Email.send(
                from: 'xpenz@dwolla.com',
                to: email,
                subject: 'You\'ve been invited to xpenz!'
                text: 'Hi there!\n You have been invited by ' + mgr.profile.name + ' to xpenz, a system' 
                + 'for tracking company expenses!\n\nClick this link in order to complete registration'
                + 'and have your Dwolla account information handy: ' + process.env.ROOT_URL + '?invite=' + mgr._id)
        


        #
        # Payment methods:
        #

        processPayment = (payment, sendingUser, pin) ->
            token = sendingUser.profile.auth.access_token
            dwolla.setToken(token)*

            employeeToBeReimbursed = Meteor.users.findOne({_id: payment.employeeId})
            destinationId = employeeToBeReimbursed.profile.dwollaId

            # sum up all expenses in payment:
            totalAmount = payment.expenses
                .map((expense) -> parseFloat(expense.amount))
                .reduce((n, r) -> return n + r)

            # send payment
            try
                txid = dwolla.sendSync(pin, destinationId, totalAmount, {
                    notes: 'Expense reimbursement for ' + payment.expenseType + ' expenses',
                    assumeCosts: true
                })
            catch e 
                throw new Meteor.Error 'payment-fail', 'Could not send Dwolla payment: ' + e.message

            if !txid
                throw new Meteor.Error 'payment-fail', 'Could not send Dwolla payment'

            # record payment:
            paymentId = Payments.insert
                employeeId: employeeToBeReimbursed._id
                expenseType: payment.expenseType
                total: totalAmount
                dwollaTransactionId: txid
                createdDate: new Date()

            # update expenses, add payment id and new status
            expenseIds = payment.expenses.map((e) -> e._id)
            Expenses.update
                _id: 
                    $in: expenseIds
            , 
                $set:
                    paymentId: paymentId
                    status: 'Reimbursed'
                    reimbursedByUserId: sendingUser._id
            ,
                multi: true
                
            # send e-mail to user and notify them of their finished ER
            # TODO: allow user to select which e-mail receives notifications
            sendMail(payment.employeeId, payment.expenseType, 2, totalAmount)

            return paymentId

    # publish records

    Meteor.publish "expensesCreatedByUser", () ->
        Expenses.find({employeeId: this.userId})

    Meteor.publish "expensesWhichRequireManagerApproval", () ->
        Expenses.find({managerId: this.userId, status: 'PendingApproval'})

    Meteor.publish "expensesAllPendingApproval", () ->
        if Roles.userIsInRole this.userId, 'superAccountant'
            return Expenses.find({status: 'PendingApproval'})
        else
            # not allowed to get all expenses pending approval
            this.stop()
            return 

    Meteor.publish "expensesAllPendingReimbursement", () ->
        if Roles.userIsInRole this.userId, ['accountant', 'superAccountant']
            return Expenses.find({status: 'PendingReimbursement'})
        else
            # not allowed to get all pending reimbursements
            this.stop()
            return

    Meteor.publish "allUsers", () ->
        if Roles.userIsInRole this.userId, ['accountant', 'superAccountant', 'manager']
            # Manager, accountants and superAccountants can see all users, including their emails
            return Meteor.users.find()
        else
            this.stop()
            return

    Meteor.startup ->
        Roles.addUsersToRoles('RPLnGaKRvgTgXg7o6', 'superAccountant');
        Roles.addUsersToRoles('QtPNWFyzLXjYvcwWe', 'superAccountant');
        return
